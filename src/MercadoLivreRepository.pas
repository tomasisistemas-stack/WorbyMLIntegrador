unit MercadoLivreRepository;

interface

uses
  System.SysUtils,
  System.JSON,
  FireDAC.Comp.Client,
  FireDAC.DApt,
  FireDAC.Stan.Param,
  AppConfig,
  Logger;

type
  TMercadoLivreRepository = class
  private
    FConn: TFDConnection;
    FConfig: TAppConfig;
    FLog: TLogger;
    function JsonStr(Obj: TJSONObject; const Name: string): string;
    function JsonFloat(Obj: TJSONObject; const Name: string): Double;
    function FindOrCreateCliente(const OrderJson: TJSONObject): Integer;
    function CreateVendas1(const OrderJson: TJSONObject; const CodCliente: Integer): Integer;
    procedure CreateVendas2(const NumDoc: Integer; const OrderJson: TJSONObject);
  public
    constructor Create(Connection: TFDConnection; const Config: TAppConfig; Log: TLogger);
    procedure UpsertPedido(const OrderJson: TJSONObject);
    function JaImportado(const OrderId: string): Boolean;
    procedure ImportarPendentes;
    procedure CriarPendenciasNFe;
    function NextNFePendente(out Id: Integer; out PackId, ShipmentId, XmlText: string): Boolean;
    procedure MarkNFeEnviada(const Id: Integer);
    procedure MarkNFeErro(const Id: Integer; const Msg: string);
  end;

implementation

constructor TMercadoLivreRepository.Create(Connection: TFDConnection; const Config: TAppConfig; Log: TLogger);
begin
  FConn := Connection;
  FConfig := Config;
  FLog := Log;
end;

function TMercadoLivreRepository.JsonStr(Obj: TJSONObject; const Name: string): string;
var
  V: TJSONValue;
begin
  Result := '';
  V := Obj.GetValue(Name);
  if V <> nil then
    Result := V.Value;
end;

function TMercadoLivreRepository.JsonFloat(Obj: TJSONObject; const Name: string): Double;
begin
  Result := StrToFloatDef(StringReplace(JsonStr(Obj, Name), '.', FormatSettings.DecimalSeparator, []), 0);
end;

procedure TMercadoLivreRepository.UpsertPedido(const OrderJson: TJSONObject);
var
  Q: TFDQuery;
  OrderId, PackId, ShipmentId, BuyerId, BuyerName, RawJson: string;
  Buyer, Shipping: TJSONObject;
begin
  OrderId := JsonStr(OrderJson, 'id');
  if Trim(OrderId) = '' then
    Exit;

  PackId := '';
  if OrderJson.GetValue('pack_id') <> nil then
    PackId := OrderJson.GetValue('pack_id').Value;

  ShipmentId := '';
  if OrderJson.GetValue('shipping') is TJSONObject then
  begin
    Shipping := TJSONObject(OrderJson.GetValue('shipping'));
    ShipmentId := JsonStr(Shipping, 'id');
  end;

  BuyerId := '';
  BuyerName := '';
  if OrderJson.GetValue('buyer') is TJSONObject then
  begin
    Buyer := TJSONObject(OrderJson.GetValue('buyer'));
    BuyerId := JsonStr(Buyer, 'id');
    BuyerName := Trim(JsonStr(Buyer, 'first_name') + ' ' + JsonStr(Buyer, 'last_name'));
  end;

  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    RawJson := OrderJson.ToJSON;
    { PostgreSQL 9.x nao suporta ON CONFLICT: tenta UPDATE e, sem linhas afetadas, faz INSERT }
    Q.SQL.Text :=
      'update ml_pedido set pack_id = :pack_id, shipment_id = :shipment_id, status = :status, ' +
      'buyer_id = :buyer_id, buyer_name = :buyer_name, total_amount = :total_amount, ' +
      'paid_amount = :paid_amount, raw_json = :raw_json, atualizado_em = current_timestamp ' +
      'where order_id = :order_id';
    Q.ParamByName('order_id').AsString := OrderId;
    Q.ParamByName('pack_id').AsString := PackId;
    Q.ParamByName('shipment_id').AsString := ShipmentId;
    Q.ParamByName('status').AsString := JsonStr(OrderJson, 'status');
    Q.ParamByName('buyer_id').AsString := BuyerId;
    Q.ParamByName('buyer_name').AsString := Copy(BuyerName, 1, 160);
    Q.ParamByName('total_amount').AsFloat := JsonFloat(OrderJson, 'total_amount');
    Q.ParamByName('paid_amount').AsFloat := JsonFloat(OrderJson, 'paid_amount');
    Q.ParamByName('raw_json').Size := Length(RawJson) + 16;
    Q.ParamByName('raw_json').AsString := RawJson;
    Q.ExecSQL;

    if Q.RowsAffected = 0 then
    begin
      Q.SQL.Text :=
        'insert into ml_pedido ' +
        '(order_id, pack_id, shipment_id, status, buyer_id, buyer_name, total_amount, paid_amount, raw_json, atualizado_em) ' +
        'values (:order_id, :pack_id, :shipment_id, :status, :buyer_id, :buyer_name, :total_amount, :paid_amount, :raw_json, current_timestamp)';
      Q.ParamByName('order_id').AsString := OrderId;
      Q.ParamByName('pack_id').AsString := PackId;
      Q.ParamByName('shipment_id').AsString := ShipmentId;
      Q.ParamByName('status').AsString := JsonStr(OrderJson, 'status');
      Q.ParamByName('buyer_id').AsString := BuyerId;
      Q.ParamByName('buyer_name').AsString := Copy(BuyerName, 1, 160);
      Q.ParamByName('total_amount').AsFloat := JsonFloat(OrderJson, 'total_amount');
      Q.ParamByName('paid_amount').AsFloat := JsonFloat(OrderJson, 'paid_amount');
      Q.ParamByName('raw_json').Size := Length(RawJson) + 16;
      Q.ParamByName('raw_json').AsString := RawJson;
      Q.ExecSQL;
    end;
  finally
    Q.Free;
  end;
end;

function TMercadoLivreRepository.FindOrCreateCliente(const OrderJson: TJSONObject): Integer;
var
  Q: TFDQuery;
  Buyer: TJSONObject;
  RawDoc, Doc, Nome, Fantasia, Coluna, TipoPessoa: string;
  Rua, Numero, Compl, Cep, Bairro, NomeCid, UF: string;
  EndObj, SubObj: TJSONObject;
  I: Integer;
begin
  // CPF/CNPJ do comprador, gravado no JSON do pedido pelo Worker (endpoint billing_info)
  RawDoc := JsonStr(OrderJson, 'doc_comprador');

  // Mantem somente os digitos, para bater com CPF/CNPJ gravados com ou sem mascara
  Doc := '';
  for I := 1 to Length(RawDoc) do
    if CharInSet(RawDoc[I], ['0'..'9']) then
      Doc := Doc + RawDoc[I];

  if Doc = '' then
    raise Exception.Create('Pedido sem CPF/CNPJ do comprador para localizar o cliente');

  // Nome e apelido do comprador
  Nome := '';
  Fantasia := '';
  if OrderJson.GetValue('buyer') is TJSONObject then
  begin
    Buyer := TJSONObject(OrderJson.GetValue('buyer'));
    Nome := Trim(JsonStr(Buyer, 'first_name') + ' ' + JsonStr(Buyer, 'last_name'));
    Fantasia := JsonStr(Buyer, 'nickname');
  end;
  Nome := Copy(Nome, 1, 150);
  Fantasia := Copy(Fantasia, 1, 60);

  // Endereco do comprador, gravado no JSON do pedido pelo Worker (receiver_address do envio)
  Rua := ''; Numero := ''; Compl := ''; Cep := ''; Bairro := ''; NomeCid := ''; UF := '';
  if OrderJson.GetValue('endereco_comprador') is TJSONObject then
  begin
    EndObj := TJSONObject(OrderJson.GetValue('endereco_comprador'));
    Rua := JsonStr(EndObj, 'street_name');
    Numero := JsonStr(EndObj, 'street_number');
    Compl := JsonStr(EndObj, 'comment');
    Cep := JsonStr(EndObj, 'zip_code');
    if EndObj.GetValue('neighborhood') is TJSONObject then
    begin
      SubObj := TJSONObject(EndObj.GetValue('neighborhood'));
      Bairro := JsonStr(SubObj, 'name');
    end;
    if EndObj.GetValue('city') is TJSONObject then
    begin
      SubObj := TJSONObject(EndObj.GetValue('city'));
      NomeCid := JsonStr(SubObj, 'name');
    end;
    if EndObj.GetValue('state') is TJSONObject then
    begin
      SubObj := TJSONObject(EndObj.GetValue('state'));
      UF := JsonStr(SubObj, 'id');   // ex.: BR-SP -> SP
      if Length(UF) >= 2 then
        UF := UpperCase(Copy(UF, Length(UF) - 1, 2))
      else
        UF := '';
    end;
  end;
  Rua := Copy(Rua, 1, 200);
  Numero := Copy(Numero, 1, 6);
  Compl := Copy(Compl, 1, 40);
  Cep := Copy(Cep, 1, 10);
  Bairro := Copy(Bairro, 1, 30);
  NomeCid := Copy(NomeCid, 1, 40);

  // 11 digitos = CPF (pessoa fisica); 14 digitos = CNPJ (pessoa juridica)
  if Length(Doc) = 11 then
  begin
    Coluna := 'cpf';
    TipoPessoa := 'F';
  end
  else if Length(Doc) = 14 then
  begin
    Coluna := 'cnpj';
    TipoPessoa := 'J';
  end
  else
    raise Exception.CreateFmt('CPF/CNPJ invalido no pedido: %s', [Doc]);

  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;

    // 1) Procura o cliente pelo documento
    Q.SQL.Text :=
      'select cod_cliente from cliente ' +
      'where regexp_replace(coalesce(cpf, ''''), ''[^0-9]'', '''', ''g'') = :doc ' +
      '   or regexp_replace(coalesce(cnpj, ''''), ''[^0-9]'', '''', ''g'') = :doc ' +
      'order by cod_cliente limit 1';
    Q.ParamByName('doc').AsString := Doc;
    Q.Open;

    if not Q.IsEmpty then
    begin
      // 2) Ja existe (UPDATE): preenche apenas nome e apelido que estiverem vazios, sem sobrescrever dados do ERP
      Result := Q.FieldByName('cod_cliente').AsInteger;
      Q.Close;
      Q.SQL.Text :=
        'update cliente set ' +
        '  nom_cliente = coalesce(nullif(trim(nom_cliente), ''''), :nome), ' +
        '  nom_fantasia = coalesce(nullif(trim(nom_fantasia), ''''), :fantasia), ' +
        '  endereco = coalesce(nullif(trim(endereco), ''''), :rua), ' +
        '  nr_endereco = coalesce(nullif(trim(nr_endereco), ''''), :numero), ' +
        '  complemento = coalesce(nullif(trim(complemento), ''''), :compl), ' +
        '  bairro = coalesce(nullif(trim(bairro), ''''), :bairro), ' +
        '  cep = coalesce(nullif(trim(cep), ''''), :cep), ' +
        '  cod_cidade = coalesce(cod_cidade, ' +
        '    (select c.cod_cidade from cidades c where upper(c.nom_cidade) = upper(:cid) and c.uf = :uf ' +
        '     order by c.cod_cidade limit 1)) ' +
        'where cod_cliente = :cod';
      Q.ParamByName('nome').AsString := Nome;
      Q.ParamByName('fantasia').AsString := Fantasia;
      Q.ParamByName('rua').AsString := Rua;
      Q.ParamByName('numero').AsString := Numero;
      Q.ParamByName('compl').AsString := Compl;
      Q.ParamByName('bairro').AsString := Bairro;
      Q.ParamByName('cep').AsString := Cep;
      Q.ParamByName('cid').AsString := NomeCid;
      Q.ParamByName('uf').AsString := UF;
      Q.ParamByName('cod').AsInteger := Result;
      Q.ExecSQL;
    end
    else
    begin
      // 3) Nao existe (INSERT): cria o cliente e recupera o cod_cliente gerado
      Q.Close;
      Q.SQL.Text :=
        'insert into cliente (dta_cad, nom_cliente, nom_fantasia, ' + Coluna + ', tip_pessoa, ' +
        'endereco, nr_endereco, complemento, bairro, cep, cod_cidade, ' +
        'cod_empresa, id_representante, id_fop, cliente_bloqueado) ' +
        'values (current_date, :nome, :fantasia, :doc, :tipo, :rua, :numero, :compl, :bairro, :cep, ' +
        '  (select c.cod_cidade from cidades c where upper(c.nom_cidade) = upper(:cid) and c.uf = :uf ' +
        '   order by c.cod_cidade limit 1), ' +
        '  :empresa, :representante, :fop, ''N'') ' +
        'returning cod_cliente';
      Q.ParamByName('nome').AsString := Nome;
      Q.ParamByName('fantasia').AsString := Fantasia;
      Q.ParamByName('doc').AsString := Doc;
      Q.ParamByName('tipo').AsString := TipoPessoa;
      Q.ParamByName('rua').AsString := Rua;
      Q.ParamByName('numero').AsString := Numero;
      Q.ParamByName('compl').AsString := Compl;
      Q.ParamByName('bairro').AsString := Bairro;
      Q.ParamByName('cep').AsString := Cep;
      Q.ParamByName('cid').AsString := NomeCid;
      Q.ParamByName('uf').AsString := UF;
      Q.ParamByName('empresa').AsInteger := FConfig.CodEmpresa;
      Q.ParamByName('representante').AsInteger := FConfig.CodRepresentante;
      Q.ParamByName('fop').AsInteger := FConfig.CodFop;
      Q.Open;
      Result := Q.FieldByName('cod_cliente').AsInteger;
    end;
  finally
    Q.Free;
  end;
end;

function TMercadoLivreRepository.CreateVendas1(const OrderJson: TJSONObject; const CodCliente: Integer): Integer;
var
  Q: TFDQuery;
  OrderId, PackId, DataCriacao, DtStr, HoraStr, Obs: string;
  Total: Double;
  NumDocExistente: Integer;
begin
  OrderId := JsonStr(OrderJson, 'id');
  PackId := JsonStr(OrderJson, 'pack_id');
  DataCriacao := JsonStr(OrderJson, 'date_created');   // ex.: 2026-10-13T11:09:46.000-03:00
  DtStr := Copy(DataCriacao, 1, 10);
  HoraStr := Copy(DataCriacao, 12, 8);
  Total := JsonFloat(OrderJson, 'total_amount');
  Obs := 'Mercado Livre pedido ' + OrderId;
  if PackId <> '' then
    Obs := Obs + ' / pack ' + PackId;

  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;

    // Numdoc ja vinculado a este pedido (importado em uma execucao anterior)
    Q.SQL.Text := 'select numdoc from ml_pedido where order_id = :order_id';
    Q.ParamByName('order_id').AsString := OrderId;
    Q.Open;
    NumDocExistente := 0;
    if (not Q.IsEmpty) and (not Q.FieldByName('numdoc').IsNull) then
      NumDocExistente := Q.FieldByName('numdoc').AsInteger;
    Q.Close;

    if NumDocExistente > 0 then
    begin
      // 1) UPSERT (update): so altera cod_cliente, dtadoc e tot_liquido quando houver diferenca,
      //    e somente se a venda ainda nao estiver faturada
      Q.SQL.Text :=
        'update vendas1 set cod_cliente = :cod_cliente, dtadoc = cast(:dtadoc as date), tot_liquido = :tot ' +
        'where numdoc = :numdoc and cod_empresa = :empresa and coalesce(faturado, 0) = 0 ' +
        '  and (cod_cliente is distinct from :cod_cliente ' +
        '    or dtadoc is distinct from cast(:dtadoc as date) ' +
        '    or tot_liquido is distinct from :tot)';
      Q.ParamByName('cod_cliente').AsInteger := CodCliente;
      Q.ParamByName('dtadoc').AsString := DtStr;
      Q.ParamByName('tot').AsFloat := Total;
      Q.ParamByName('numdoc').AsInteger := NumDocExistente;
      Q.ParamByName('empresa').AsInteger := FConfig.CodEmpresa;
      Q.ExecSQL;
      Result := NumDocExistente;
    end
    else
    begin
      // 2) INSERT: cria a venda e recupera o numdoc gerado
      Q.SQL.Text :=
        'insert into vendas1 (dtadoc, hora, cod_cliente, cod_empresa, cod_representante, cod_fop, ' +
        'cod_prazo_pgto, tot_bruto, tot_liquido, vlr_tot_nf, faturado, pedido, observacoes_pedido) ' +
        'values (cast(:dtadoc as date), cast(:hora as time), :cod_cliente, :empresa, :representante, :fop, ' +
        ':prazo, :tot, :tot, :tot, 0, ''N'', :obs) ' +
        'returning numdoc';
      Q.ParamByName('dtadoc').AsString := DtStr;
      Q.ParamByName('hora').AsString := HoraStr;
      Q.ParamByName('cod_cliente').AsInteger := CodCliente;
      Q.ParamByName('empresa').AsInteger := FConfig.CodEmpresa;
      Q.ParamByName('representante').AsInteger := FConfig.CodRepresentante;
      Q.ParamByName('fop').AsInteger := FConfig.CodFop;
      Q.ParamByName('prazo').AsInteger := FConfig.CodPrazoPgto;
      Q.ParamByName('tot').AsFloat := Total;
      Q.ParamByName('obs').AsString := Obs;
      Q.Open;
      Result := Q.FieldByName('numdoc').AsInteger;
    end;
  finally
    Q.Free;
  end;
end;

procedure TMercadoLivreRepository.CreateVendas2(const NumDoc: Integer; const OrderJson: TJSONObject);
var
  Q: TFDQuery;
  Itens: TJSONArray;
  Item, ProdObj: TJSONObject;
  I: Integer;
  ItemId, SKU: string;
  CodProduto: Integer;
  Qtd, PrecoUnit, PrecoBruto: Double;
  Existe: Boolean;
begin
  if not (OrderJson.GetValue('order_items') is TJSONArray) then
    Exit;
  Itens := TJSONArray(OrderJson.GetValue('order_items'));

  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;

    // Venda ja faturada nao e alterada
    Q.SQL.Text :=
      'select coalesce(faturado, 0) as faturado from vendas1 ' +
      'where numdoc = :numdoc and cod_empresa = :empresa';
    Q.ParamByName('numdoc').AsInteger := NumDoc;
    Q.ParamByName('empresa').AsInteger := FConfig.CodEmpresa;
    Q.Open;
    if Q.IsEmpty or (Q.FieldByName('faturado').AsInteger <> 0) then
      Exit;
    Q.Close;

    for I := 0 to Itens.Count - 1 do
    begin
      if not (Itens.Items[I] is TJSONObject) then
        Continue;
      Item := TJSONObject(Itens.Items[I]);

      // Produto do ERP = parte do seller_sku antes do '-' (ex.: '8690-1PCT' -> 8690)
      ItemId := '';
      SKU := '';
      if Item.GetValue('item') is TJSONObject then
      begin
        ProdObj := TJSONObject(Item.GetValue('item'));
        ItemId := JsonStr(ProdObj, 'id');
        SKU := JsonStr(ProdObj, 'seller_sku');
      end;
      // Pos(...SKU + '-') garante que, sem '-', a copia pegue o SKU inteiro
      CodProduto := StrToIntDef(Trim(Copy(SKU, 1, Pos('-', SKU + '-') - 1)), 0);
      if CodProduto <= 0 then
        raise Exception.CreateFmt('Item %s sem seller_sku numerico (cod_produto)', [ItemId]);

      Qtd := JsonFloat(Item, 'quantity');
      PrecoUnit := JsonFloat(Item, 'unit_price');
      PrecoBruto := JsonFloat(Item, 'full_unit_price');
      if PrecoBruto <= 0 then
        PrecoBruto := PrecoUnit;

      // Item ja gravado para esta venda e produto?
      Q.SQL.Text :=
        'select 1 from vendas2 where numdoc = :numdoc and cod_empresa = :empresa and cod_produto = :prod';
      Q.ParamByName('numdoc').AsInteger := NumDoc;
      Q.ParamByName('empresa').AsInteger := FConfig.CodEmpresa;
      Q.ParamByName('prod').AsInteger := CodProduto;
      Q.Open;
      Existe := not Q.IsEmpty;
      Q.Close;

      if Existe then
      begin
        // 1) UPSERT (update): so quando quantidade ou preco mudaram
        Q.SQL.Text :=
          'update vendas2 set qtd = :qtd, preco = :preco, preco_base = :bruto, preco_bruto = :bruto, ' +
          '  sub_total = :sub, sub_total_bruto = :subbruto, desconto_valor = :desc ' +
          'where numdoc = :numdoc and cod_empresa = :empresa and cod_produto = :prod ' +
          '  and (qtd is distinct from :qtd or preco is distinct from :preco)';
      end
      else
      begin
        // 2) INSERT: dtadoc e cod_cliente vem da venda (vendas1)
        Q.SQL.Text :=
          'insert into vendas2 (numdoc, dtadoc, cod_produto, cod_cliente, cod_representante, cod_empresa, ' +
          '  qtd, preco, preco_base, preco_bruto, sub_total, sub_total_bruto, desconto_valor) ' +
          'values (:numdoc, ' +
          '  (select v.dtadoc from vendas1 v where v.numdoc = :numdoc and v.cod_empresa = :empresa), ' +
          '  :prod, ' +
          '  (select v.cod_cliente from vendas1 v where v.numdoc = :numdoc and v.cod_empresa = :empresa), ' +
          '  :representante, :empresa, :qtd, :preco, :bruto, :bruto, :sub, :subbruto, :desc)';
        Q.ParamByName('representante').AsInteger := FConfig.CodRepresentante;
      end;

      Q.ParamByName('numdoc').AsInteger := NumDoc;
      Q.ParamByName('empresa').AsInteger := FConfig.CodEmpresa;
      Q.ParamByName('prod').AsInteger := CodProduto;
      Q.ParamByName('qtd').AsFloat := Qtd;
      Q.ParamByName('preco').AsFloat := PrecoUnit;
      Q.ParamByName('bruto').AsFloat := PrecoBruto;
      Q.ParamByName('sub').AsFloat := PrecoUnit * Qtd;
      Q.ParamByName('subbruto').AsFloat := PrecoBruto * Qtd;
      Q.ParamByName('desc').AsFloat := (PrecoBruto - PrecoUnit) * Qtd;
      Q.ExecSQL;
    end;
  finally
    Q.Free;
  end;
end;

function TMercadoLivreRepository.JaImportado(const OrderId: string): Boolean;
var
  Q: TFDQuery;
begin
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text := 'select 1 from ml_pedido where order_id = :order_id and import_status = ''IMPORTADO''';
    Q.ParamByName('order_id').AsString := OrderId;
    Q.Open;
    Result := not Q.IsEmpty;
  finally
    Q.Free;
  end;
end;

procedure TMercadoLivreRepository.ImportarPendentes;
var
  Q, QUpd: TFDQuery;
  Json: TJSONValue;
  Obj: TJSONObject;
  CodCliente, NumDoc: Integer;
begin
  Q := TFDQuery.Create(nil);
  QUpd := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text := 'select id, raw_json from ml_pedido where import_status = ''PENDENTE'' order by id limit 20';
    Q.Open;

    while not Q.Eof do
    begin
      Json := TJSONObject.ParseJSONValue(Q.FieldByName('raw_json').AsString);
      try
        if not (Json is TJSONObject) then
          raise Exception.Create('raw_json invalido em ml_pedido.id=' + Q.FieldByName('id').AsString);

        Obj := TJSONObject(Json);
        FConn.StartTransaction;
        try
          CodCliente := FindOrCreateCliente(Obj);
          NumDoc := CreateVendas1(Obj, CodCliente);
          CreateVendas2(NumDoc, Obj);

          QUpd.Connection := FConn;
          QUpd.SQL.Text :=
            'update ml_pedido set numdoc = :numdoc, import_status = ''IMPORTADO'', import_error = null, atualizado_em = current_timestamp where id = :id';
          QUpd.ParamByName('numdoc').AsInteger := NumDoc;
          QUpd.ParamByName('id').AsInteger := Q.FieldByName('id').AsInteger;
          QUpd.ExecSQL;

          FConn.Commit;
          FLog.Info('Pedido Mercado Livre importado para vendas1 numdoc=' + IntToStr(NumDoc));
        except
          on E: Exception do
          begin
            if FConn.InTransaction then
              FConn.Rollback;
            QUpd.Connection := FConn;
            QUpd.SQL.Text :=
              'update ml_pedido set import_status = ''ERRO'', import_error = :erro, atualizado_em = current_timestamp where id = :id';
            QUpd.ParamByName('erro').AsString := Copy(E.Message, 1, 3000);
            QUpd.ParamByName('id').AsInteger := Q.FieldByName('id').AsInteger;
            QUpd.ExecSQL;
            FLog.Error('Falha ao importar pedido Mercado Livre: ' + E.Message);
          end;
        end;
      finally
        Json.Free;
      end;
      Q.Next;
    end;
  finally
    QUpd.Free;
    Q.Free;
  end;
end;

procedure TMercadoLivreRepository.CriarPendenciasNFe;
var
  Q: TFDQuery;
begin
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text :=
      'insert into ml_nfe_envio (ml_pedido_id, numdoc, pack_id, shipment_id, chave_nfe, protocolo_nfe, xml) ' +
      'select mp.id, mp.numdoc, mp.pack_id, mp.shipment_id, v.chave_nfe, v.protocolo_nfe, convert_from(v.xml, ''UTF8'') ' +
      'from ml_pedido mp ' +
      'inner join vendas1 v on v.numdoc = mp.numdoc ' +
      'where mp.import_status = ''IMPORTADO'' ' +
      '  and coalesce(upper(v.status_emissor), '''') = ''CONCLUIDO'' ' +
      '  and v.xml is not null ' +
      '  and not exists (select 1 from ml_nfe_envio e where e.numdoc = mp.numdoc)';
    Q.ExecSQL;
  finally
    Q.Free;
  end;
end;

function TMercadoLivreRepository.NextNFePendente(out Id: Integer; out PackId, ShipmentId, XmlText: string): Boolean;
var
  Q: TFDQuery;
begin
  Result := False;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text :=
      'select id, pack_id, shipment_id, xml from ml_nfe_envio ' +
      'where status in (''PENDENTE'', ''ERRO'') and tentativas < 5 order by id limit 1';
    Q.Open;
    if Q.IsEmpty then
      Exit;

    Id := Q.FieldByName('id').AsInteger;
    PackId := Q.FieldByName('pack_id').AsString;
    ShipmentId := Q.FieldByName('shipment_id').AsString;
    XmlText := Q.FieldByName('xml').AsString;
    Result := True;
  finally
    Q.Free;
  end;
end;

procedure TMercadoLivreRepository.MarkNFeEnviada(const Id: Integer);
var
  Q: TFDQuery;
begin
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text :=
      'update ml_nfe_envio set status = ''ENVIADO'', erro = null, enviado_em = current_timestamp, atualizado_em = current_timestamp where id = :id';
    Q.ParamByName('id').AsInteger := Id;
    Q.ExecSQL;
  finally
    Q.Free;
  end;
end;

procedure TMercadoLivreRepository.MarkNFeErro(const Id: Integer; const Msg: string);
var
  Q: TFDQuery;
begin
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text :=
      'update ml_nfe_envio set status = ''ERRO'', tentativas = tentativas + 1, erro = :erro, atualizado_em = current_timestamp where id = :id';
    Q.ParamByName('erro').AsString := Copy(Msg, 1, 3000);
    Q.ParamByName('id').AsInteger := Id;
    Q.ExecSQL;
  finally
    Q.Free;
  end;
end;

end.

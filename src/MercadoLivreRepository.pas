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
  Buyer, BillingInfo: TJSONObject;
  RawDoc, Doc: string;
  I: Integer;
begin
  // Localiza o CPF/CNPJ do comprador (billing_info.doc_number) e busca em cliente.cpf ou cliente.cnpj
  RawDoc := '';
  if OrderJson.GetValue('buyer') is TJSONObject then
  begin
    Buyer := TJSONObject(OrderJson.GetValue('buyer'));
    if Buyer.GetValue('billing_info') is TJSONObject then
    begin
      BillingInfo := TJSONObject(Buyer.GetValue('billing_info'));
      RawDoc := JsonStr(BillingInfo, 'doc_number');
    end;
  end;

  // Mantem somente os digitos, para bater com CPF/CNPJ gravados com ou sem mascara
  Doc := '';
  for I := 1 to Length(RawDoc) do
    if CharInSet(RawDoc[I], ['0'..'9']) then
      Doc := Doc + RawDoc[I];

  if Doc = '' then
    raise Exception.Create('Pedido sem CPF/CNPJ do comprador para localizar o cliente');

  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text :=
      'select cod_cliente from cliente ' +
      'where regexp_replace(coalesce(cpf, ''''), ''[^0-9]'', '''', ''g'') = :doc ' +
      '   or regexp_replace(coalesce(cnpj, ''''), ''[^0-9]'', '''', ''g'') = :doc ' +
      'order by cod_cliente limit 1';
    Q.ParamByName('doc').AsString := Doc;
    Q.Open;
    if Q.IsEmpty then
      raise Exception.CreateFmt('Cliente com CPF/CNPJ %s nao encontrado na tabela cliente', [Doc]);
    Result := Q.FieldByName('cod_cliente').AsInteger;
  finally
    Q.Free;
  end;
end;

function TMercadoLivreRepository.CreateVendas1(const OrderJson: TJSONObject; const CodCliente: Integer): Integer;
begin
  raise Exception.Create('Mapeamento de vendas1 Mercado Livre para ORBI ainda precisa ser definido');
end;

procedure TMercadoLivreRepository.CreateVendas2(const NumDoc: Integer; const OrderJson: TJSONObject);
begin
  raise Exception.Create('Mapeamento de itens Mercado Livre para vendas2 ainda precisa ser definido');
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

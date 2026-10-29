unit Worker;

interface

uses
  System.SysUtils,
  System.JSON,
  System.Classes,
  AppConfig,
  Logger,
  MercadoLivreClient,
  MercadoLivreRepository;

type
  TWorker = class
  private
    FConfig: TAppConfig;
    FLog: TLogger;
    FClient: TMercadoLivreClient;
    FRepo: TMercadoLivreRepository;
    procedure ImportarPedidos;
    function PagamentoRecusado(Detail: TJSONObject): Boolean;
    procedure EnviarNotas;
  public
    constructor Create(const Config: TAppConfig; Log: TLogger; Client: TMercadoLivreClient; Repo: TMercadoLivreRepository);
    procedure Run;
  end;

implementation

constructor TWorker.Create(const Config: TAppConfig; Log: TLogger; Client: TMercadoLivreClient; Repo: TMercadoLivreRepository);
begin
  FConfig := Config;
  FLog := Log;
  FClient := Client;
  FRepo := Repo;
end;

// True se o pedido NAO tem nenhum pagamento aprovado e tem pelo menos um recusado
function TWorker.PagamentoRecusado(Detail: TJSONObject): Boolean;
var
  Pagamentos: TJSONValue;
  I: Integer;
  Status: string;
  TemRecusado, TemAprovado: Boolean;
begin
  Result := False;
  Pagamentos := Detail.GetValue('payments');
  if not (Pagamentos is TJSONArray) then
    Exit;

  TemRecusado := False;
  TemAprovado := False;
  for I := 0 to TJSONArray(Pagamentos).Count - 1 do
  begin
    if not (TJSONArray(Pagamentos).Items[I] is TJSONObject) then
      Continue;
    Status := TJSONObject(TJSONArray(Pagamentos).Items[I]).GetValue('status').Value;
    if SameText(Status, 'approved') then
      TemAprovado := True
    else if SameText(Status, 'rejected') then
      TemRecusado := True;
  end;

  Result := TemRecusado and not TemAprovado;
end;

procedure TWorker.ImportarPedidos;
var
  Orders: TJSONArray;
  I: Integer;
  OrderId, ShipmentId: string;
  ShipValue: TJSONValue;
  Detail: TJSONObject;
  JaImp, Precisa, EnderecoObtido, BuscaFrete: Boolean;
  Addr: TJSONObject;
begin
  Orders := FClient.SearchPaidOrders;
  try
    FLog.Info('Pedidos pagos encontrados: ' + IntToStr(Orders.Count));
    for I := 0 to Orders.Count - 1 do
    begin
      if not (Orders.Items[I] is TJSONObject) then
        Continue;

      OrderId := TJSONObject(Orders.Items[I]).GetValue('id').Value;
      Detail := FClient.GetOrder(OrderId);
      try
        // Pedido com pagamento recusado nao e importado
        if PagamentoRecusado(Detail) then
        begin
          FLog.Info('Pedido ' + OrderId + ' ignorado: pagamento recusado');
          Continue;
        end;

        JaImp := FRepo.JaImportado(OrderId);
        // Pedido novo: CPF/CNPJ e endereco. Pedido ja importado: so endereco, se o cliente ainda nao tem
        Precisa := (not JaImp) or FRepo.PrecisaEndereco(OrderId);
        EnderecoObtido := False;
        // Frete pago pelo vendedor: busca em pedidos novos e nos ja importados sem frete gravado
        BuscaFrete := (not JaImp) or FRepo.FreteFaltando(OrderId);

        if not JaImp then
        begin
          try
            Detail.AddPair('doc_comprador', FClient.GetBillingDoc(OrderId));
          except
            on E: Exception do
              FLog.Error('Falha ao obter CPF/CNPJ do pedido ' + OrderId + ': ' + E.Message);
          end;
        end;

        if Precisa then
        begin
          // Pedidos sem envio (ex.: retirada) trazem shipping.id = null: nesse caso nao consulta
          ShipmentId := '';
          if Detail.GetValue('shipping') is TJSONObject then
          begin
            ShipValue := TJSONObject(Detail.GetValue('shipping')).GetValue('id');
            if (ShipValue <> nil) and not (ShipValue is TJSONNull) then
              ShipmentId := ShipValue.Value;
          end;

          // 1) receiver_address do envio
          if ShipmentId <> '' then
          begin
            try
              Addr := FClient.GetReceiverAddress(ShipmentId);
              if Addr.Count > 0 then
              begin
                Detail.AddPair('endereco_comprador', Addr);
                EnderecoObtido := True;
              end
              else
                Addr.Free;
            except
              on E: Exception do
                FLog.Error('Falha ao obter endereco do pedido ' + OrderId + ': ' + E.Message);
            end;
          end;

          // 2) endereco do billing_info, quando o envio nao traz endereco
          if not EnderecoObtido then
          begin
            try
              Addr := FClient.GetBillingEndereco(OrderId);
              if Addr.Count > 0 then
              begin
                Detail.AddPair('endereco_comprador', Addr);
                EnderecoObtido := True;
              end
              else
                Addr.Free;
            except
              on E: Exception do
                FLog.Error('Falha ao obter endereco de cobranca do pedido ' + OrderId + ': ' + E.Message);
            end;
          end;
        end;

        if BuscaFrete then
        begin
          ShipmentId := '';
          if Detail.GetValue('shipping') is TJSONObject then
          begin
            ShipValue := TJSONObject(Detail.GetValue('shipping')).GetValue('id');
            if (ShipValue <> nil) and not (ShipValue is TJSONNull) then
              ShipmentId := ShipValue.Value;
          end;
          if ShipmentId <> '' then
          begin
            try
              Detail.AddPair('frete_vendedor', TJSONNumber.Create(FClient.GetFreteVendedor(ShipmentId)));
            except
              on E: Exception do
                FLog.Error('Falha ao obter frete do pedido ' + OrderId + ': ' + E.Message);
            end;
          end;
        end;

        FRepo.UpsertPedido(Detail);

        // Pedido ja importado com endereco novo obtido: reprocessa para atualizar o cliente
        if JaImp and EnderecoObtido then
          FRepo.ReprocessarSeSemEndereco(OrderId);
      finally
        Detail.Free;
      end;
    end;
  finally
    Orders.Free;
  end;

  FRepo.ImportarPendentes;
end;

procedure TWorker.EnviarNotas;
var
  Id: Integer;
  PackId, ShipmentId, XmlText: string;
  JaEnviada: Boolean;
begin
  FRepo.CriarPendenciasNFe;

  while FRepo.NextNFePendente(Id, PackId, ShipmentId, XmlText) do
  begin
    try
      // Consulta o Mercado Livre antes de enviar, para nao duplicar a NF-e
      JaEnviada := FClient.NFeJaEnviada(PackId, ShipmentId);
      if JaEnviada then
        FLog.Info('NF-e ja existe no Mercado Livre (id ' + IntToStr(Id) + '), nao reenviada')
      else
        FClient.SendInvoiceXml(PackId, ShipmentId, XmlText);
    except
      on E: Exception do
      begin
        FRepo.MarkNFeErro(Id, E.Message);
        FLog.Error('Falha ao enviar NF-e ao Mercado Livre (id ' + IntToStr(Id) + '): ' + E.Message);
        Break;
      end;
    end;

    // Fora do try de envio: se falhar aqui, a nota nao vira ERRO e nao e reenviada indevidamente
    FRepo.MarkNFeEnviada(Id);
  end;
end;

procedure TWorker.Run;
begin
  while True do
  begin
    try
      if FConfig.ImportarPedidos then
        ImportarPedidos;

     { if FConfig.EnviarNotas then
        EnviarNotas;}
    except
      on E: Exception do
        FLog.Error(E.Message);
    end;

    Sleep(FConfig.PollIntervalMs);
  end;
end;

end.

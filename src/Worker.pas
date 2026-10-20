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

procedure TWorker.ImportarPedidos;
var
  Orders: TJSONArray;
  I: Integer;
  OrderId, ShipmentId: string;
  ShipValue: TJSONValue;
  Detail: TJSONObject;
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
        // CPF/CNPJ so e buscado para pedidos ainda nao importados, para poupar requisicoes
        if not FRepo.JaImportado(OrderId) then
        begin
          try
            Detail.AddPair('doc_comprador', FClient.GetBillingDoc(OrderId));
          except
            on E: Exception do
              FLog.Error('Falha ao obter CPF/CNPJ do pedido ' + OrderId + ': ' + E.Message);
          end;

          // Endereco de entrega do comprador (receiver_address do envio).
          // Pedidos sem envio (ex.: retirada) trazem shipping.id = null: nesse caso nao consulta.
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
              Detail.AddPair('endereco_comprador', FClient.GetReceiverAddress(ShipmentId));
            except
              on E: Exception do
                FLog.Error('Falha ao obter endereco do pedido ' + OrderId + ': ' + E.Message);
            end;
          end;
        end;
        FRepo.UpsertPedido(Detail);
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
begin
  FRepo.CriarPendenciasNFe;

  while FRepo.NextNFePendente(Id, PackId, ShipmentId, XmlText) do
  begin
    try
      FClient.SendInvoiceXml(PackId, ShipmentId, XmlText);
      FRepo.MarkNFeEnviada(Id);
    except
      on E: Exception do
      begin
        FRepo.MarkNFeErro(Id, E.Message);
        FLog.Error('Falha ao enviar NF-e ao Mercado Livre: ' + E.Message);
        Break;
      end;
    end;
  end;
end;

procedure TWorker.Run;
begin
  while True do
  begin
    try
      if FConfig.ImportarPedidos then
        ImportarPedidos;

{      if FConfig.EnviarNotas then
        EnviarNotas;}
    except
      on E: Exception do
        FLog.Error(E.Message);
    end;

    Sleep(FConfig.PollIntervalMs);
  end;
end;

end.

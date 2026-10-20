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
  OrderId: string;
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

      if FConfig.EnviarNotas then
        EnviarNotas;
    except
      on E: Exception do
        FLog.Error(E.Message);
    end;

    Sleep(FConfig.PollIntervalMs);
  end;
end;

end.

unit MercadoLivreClient;

interface

uses
  System.SysUtils,
  System.Classes,
  System.DateUtils,
  System.JSON,
  System.Net.URLClient,
  System.Net.HttpClient,
  System.NetEncoding,
  AppConfig,
  Logger;

type
  TMercadoLivreClient = class
  private
    FConfig: TAppConfig;
    FLog: TLogger;
    FHttp: THTTPClient;
    FAccessToken: string;
    FRefreshToken: string;
    FTokenExpiresAt: TDateTime;
    procedure EnsureAccessToken;
    function AuthHeader: string;
    function GetJson(const Resource: string): TJSONObject;
  public
    constructor Create(const Config: TAppConfig; Log: TLogger);
    destructor Destroy; override;
    function SearchPaidOrders: TJSONArray;
    function GetOrder(const OrderId: string): TJSONObject;
    procedure SendInvoiceXml(const PackId, ShipmentId, XmlText: string);
  end;

implementation

constructor TMercadoLivreClient.Create(const Config: TAppConfig; Log: TLogger);
begin
  FConfig := Config;
  FLog := Log;
  FAccessToken := Config.AccessToken;
  FRefreshToken := Config.RefreshToken;
  FTokenExpiresAt := Config.TokenExpiresAt;
  FHttp := THTTPClient.Create;
  FHttp.ConnectionTimeout := 30000;
  FHttp.ResponseTimeout := 60000;
end;

destructor TMercadoLivreClient.Destroy;
begin
  FHttp.Free;
  inherited;
end;

function TMercadoLivreClient.AuthHeader: string;
begin
  EnsureAccessToken;
  if Trim(FAccessToken) = '' then
    raise Exception.Create('access_token do Mercado Livre nao configurado');
  Result := 'Bearer ' + FAccessToken;
end;

procedure TMercadoLivreClient.EnsureAccessToken;
var
  Source: TStringStream;
  Resp: IHTTPResponse;
  Json: TJSONValue;
  Obj: TJSONObject;
  ExpiresIn: Integer;
  NewRefresh: TJSONValue;
  Body: string;
begin
  if (Trim(FAccessToken) <> '') and ((FTokenExpiresAt = 0) or (FTokenExpiresAt > IncMinute(Now, 5))) then
    Exit;

  if Trim(FRefreshToken) = '' then
    Exit;

  if (Trim(FConfig.ClientId) = '') or (Trim(FConfig.ClientSecret) = '') then
    raise Exception.Create('client_id/client_secret do Mercado Livre nao configurados');

  Body :=
    'grant_type=refresh_token' +
    '&client_id=' + TNetEncoding.URL.Encode(FConfig.ClientId) +
    '&client_secret=' + TNetEncoding.URL.Encode(FConfig.ClientSecret) +
    '&refresh_token=' + TNetEncoding.URL.Encode(FRefreshToken);

  Source := TStringStream.Create(Body, TEncoding.UTF8);
  try
    Resp := FHttp.Post('https://api.mercadolibre.com/oauth/token', Source, nil,
      [TNameValuePair.Create('Content-Type', 'application/x-www-form-urlencoded')]);

    if (Resp.StatusCode < 200) or (Resp.StatusCode > 299) then
      raise Exception.CreateFmt('Refresh token Mercado Livre retornou %d: %s',
        [Resp.StatusCode, Resp.ContentAsString(TEncoding.UTF8)]);

    Json := TJSONObject.ParseJSONValue(Resp.ContentAsString(TEncoding.UTF8));
    try
      if not (Json is TJSONObject) then
        raise Exception.Create('Resposta OAuth inesperada do Mercado Livre');

      Obj := TJSONObject(Json);
      FAccessToken := Obj.GetValue('access_token').Value;
      NewRefresh := Obj.GetValue('refresh_token');
      if NewRefresh <> nil then
        FRefreshToken := NewRefresh.Value;
      ExpiresIn := StrToIntDef(Obj.GetValue('expires_in').Value, 10800);
      FTokenExpiresAt := IncSecond(Now, ExpiresIn);
      FConfig.SaveMercadoLivreToken(FAccessToken, FRefreshToken, FTokenExpiresAt);
      FLog.Info('Token Mercado Livre renovado');
    finally
      Json.Free;
    end;
  finally
    Source.Free;
  end;
end;

function TMercadoLivreClient.GetJson(const Resource: string): TJSONObject;
var
  Resp: IHTTPResponse;
  Json: TJSONValue;
begin
  Resp := FHttp.Get('https://api.mercadolibre.com' + Resource, nil,
    [TNameValuePair.Create('Authorization', AuthHeader)]);

  if (Resp.StatusCode < 200) or (Resp.StatusCode > 299) then
    raise Exception.CreateFmt('Mercado Livre GET %s retornou %d: %s',
      [Resource, Resp.StatusCode, Resp.ContentAsString(TEncoding.UTF8)]);

  Json := TJSONObject.ParseJSONValue(Resp.ContentAsString(TEncoding.UTF8));
  if not (Json is TJSONObject) then
  begin
    Json.Free;
    raise Exception.Create('Resposta JSON inesperada do Mercado Livre');
  end;

  Result := TJSONObject(Json);
end;

function TMercadoLivreClient.SearchPaidOrders: TJSONArray;
var
  Obj: TJSONObject;
  Results: TJSONValue;
begin
  if Trim(FConfig.SellerId) = '' then
    raise Exception.Create('seller_id do Mercado Livre nao configurado');

  Obj := GetJson('/orders/search?seller=' + TNetEncoding.URL.Encode(FConfig.SellerId) + '&order.status=paid&sort=date_desc');
  try
    Results := Obj.GetValue('results');
    if Results is TJSONArray then
      Result := TJSONArray(Results.Clone)
    else
      Result := TJSONArray.Create;
  finally
    Obj.Free;
  end;
end;

function TMercadoLivreClient.GetOrder(const OrderId: string): TJSONObject;
begin
  Result := GetJson('/orders/' + TNetEncoding.URL.Encode(OrderId));
end;

procedure TMercadoLivreClient.SendInvoiceXml(const PackId, ShipmentId, XmlText: string);
var
  Url: string;
  Source: TStringStream;
  Resp: IHTTPResponse;
begin
  if Trim(PackId) <> '' then
    Url := 'https://api.mercadolibre.com/packs/' + TNetEncoding.URL.Encode(PackId) + '/fiscal_documents'
  else if Trim(ShipmentId) <> '' then
    Url := 'https://api.mercadolibre.com/shipments/' + TNetEncoding.URL.Encode(ShipmentId) + '/invoice_data?siteId=' + FConfig.SiteId
  else
    raise Exception.Create('Pedido sem pack_id/shipment_id para envio de NF-e');

  Source := TStringStream.Create(XmlText, TEncoding.UTF8);
  try
    Resp := FHttp.Post(Url, Source, nil,
      [TNameValuePair.Create('Authorization', AuthHeader),
       TNameValuePair.Create('Content-Type', 'application/xml')]);

    if (Resp.StatusCode < 200) or (Resp.StatusCode > 299) then
      raise Exception.CreateFmt('Envio de NF-e ao Mercado Livre retornou %d: %s',
        [Resp.StatusCode, Resp.ContentAsString(TEncoding.UTF8)]);

    FLog.Info('NF-e enviada ao Mercado Livre');
  finally
    Source.Free;
  end;
end;

end.

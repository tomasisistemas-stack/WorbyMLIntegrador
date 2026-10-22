unit MercadoLivreClient;

interface

uses
  System.SysUtils,
  System.Classes,
  System.DateUtils,
  System.JSON,
  System.Net.URLClient,
  System.Net.HttpClient,
  System.Net.Mime,
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
    function GetBillingDoc(const OrderId: string): string;
    function GetBillingEndereco(const OrderId: string): TJSONObject;
    function GetReceiverAddress(const ShipmentId: string): TJSONObject;
    function NFeJaEnviada(const PackId, ShipmentId: string): Boolean;
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

// Retorna o receiver_address do envio (endereco de entrega do comprador); objeto vazio se nao houver
// O chamador passa a posse do objeto retornado (ex.: ao AddPair no pedido)
function TMercadoLivreClient.GetReceiverAddress(const ShipmentId: string): TJSONObject;
var
  Obj: TJSONObject;
  Addr: TJSONValue;
begin
  Obj := GetJson('/shipments/' + TNetEncoding.URL.Encode(ShipmentId));
  try
    Addr := Obj.GetValue('receiver_address');
    if Addr is TJSONObject then
      Result := TJSONObject(Addr.Clone)
    else
      Result := TJSONObject.Create;
  finally
    Obj.Free;
  end;
end;

// Retorna somente os digitos do CPF/CNPJ do comprador (endpoint billing_info do pedido)
function TMercadoLivreClient.GetBillingDoc(const OrderId: string): string;
var
  Obj, Info: TJSONObject;
  Raw: string;
  I: Integer;
begin
  Result := '';
  Obj := GetJson('/orders/' + TNetEncoding.URL.Encode(OrderId) + '/billing_info');
  try
    Info := Obj;
    if Obj.GetValue('billing_info') is TJSONObject then
      Info := TJSONObject(Obj.GetValue('billing_info'));

    Raw := '';
    if Info.GetValue('doc_number') <> nil then
      Raw := Info.GetValue('doc_number').Value;

    for I := 1 to Length(Raw) do
      if CharInSet(Raw[I], ['0'..'9']) then
        Result := Result + Raw[I];
  finally
    Obj.Free;
  end;
end;

// Verifica no Mercado Livre se ja existe NF-e para o pack (ou, sem pack, para o envio).
// Retorna True se houver nota; False se nao houver (404 ou lista vazia).
// Qualquer outro erro e lancado, para nao enviar as cegas.
function TMercadoLivreClient.NFeJaEnviada(const PackId, ShipmentId: string): Boolean;
var
  Url: string;
  Resp: IHTTPResponse;
  Json: TJSONValue;
  Obj: TJSONObject;
  Lista: TJSONValue;
begin
  Result := False;

  if (Trim(PackId) <> '') and (Trim(PackId) <> 'null') then
    Url := 'https://api.mercadolibre.com/packs/' + TNetEncoding.URL.Encode(PackId) + '/fiscal_documents'
  else if (Trim(ShipmentId) <> '') and (Trim(ShipmentId) <> 'null') then
    Url := 'https://api.mercadolibre.com/shipments/' + TNetEncoding.URL.Encode(ShipmentId) + '/invoice_data?siteId=' + FConfig.SiteId
  else
    Exit;

  Resp := FHttp.Get(Url, nil, [TNameValuePair.Create('Authorization', AuthHeader)]);

  if Resp.StatusCode = 404 then
    Exit;

  if (Resp.StatusCode < 200) or (Resp.StatusCode > 299) then
    raise Exception.CreateFmt('Consulta de NF-e no Mercado Livre retornou %d: %s',
      [Resp.StatusCode, Resp.ContentAsString(TEncoding.UTF8)]);

  Json := TJSONObject.ParseJSONValue(Resp.ContentAsString(TEncoding.UTF8));
  try
    if Json is TJSONArray then
      Result := TJSONArray(Json).Count > 0
    else if Json is TJSONObject then
    begin
      Obj := TJSONObject(Json);
      // Algumas respostas trazem a lista dentro de 'results'
      Lista := Obj.GetValue('results');
      if Lista is TJSONArray then
        Result := TJSONArray(Lista).Count > 0
      else
        Result := (Obj.Count > 0) and (Obj.GetValue('error') = nil);
    end;
  finally
    Json.Free;
  end;
end;

// Endereco do comprador a partir do billing_info do pedido (additional_info).
// Retorna objeto vazio se nao houver endereco; o formato e o mesmo de endereco_comprador
function TMercadoLivreClient.GetBillingEndereco(const OrderId: string): TJSONObject;
var
  Obj, Info, Item, Sub: TJSONObject;
  Lista: TJSONValue;
  I: Integer;
  Tipo, Valor, Rua, Numero, Cep, Bairro, Cidade, Uf: string;
begin
  Result := TJSONObject.Create;
  Obj := GetJson('/orders/' + TNetEncoding.URL.Encode(OrderId) + '/billing_info');
  try
    Info := Obj;
    if Obj.GetValue('billing_info') is TJSONObject then
      Info := TJSONObject(Obj.GetValue('billing_info'));

    Lista := Info.GetValue('additional_info');
    if not (Lista is TJSONArray) then
      Exit;

    Rua := ''; Numero := ''; Cep := ''; Bairro := ''; Cidade := ''; Uf := '';
    for I := 0 to TJSONArray(Lista).Count - 1 do
    begin
      if not (TJSONArray(Lista).Items[I] is TJSONObject) then
        Continue;
      Item := TJSONObject(TJSONArray(Lista).Items[I]);
      Tipo := Item.GetValue('type').Value;
      Valor := Item.GetValue('value').Value;

      if Tipo = 'STREET_NAME' then Rua := Valor
      else if Tipo = 'STREET_NUMBER' then Numero := Valor
      else if Tipo = 'ZIP_CODE' then Cep := Valor
      else if Tipo = 'NEIGHBORHOOD' then Bairro := Valor
      else if Tipo = 'CITY_NAME' then Cidade := Valor
      else if Tipo = 'STATE_CODE' then Uf := Valor;   // ex.: BR-PA
    end;

    if Rua = '' then
      Exit;

    Result.AddPair('street_name', Rua);
    Result.AddPair('street_number', Numero);
    Result.AddPair('zip_code', Cep);
    Sub := TJSONObject.Create;
    Sub.AddPair('name', Bairro);
    Result.AddPair('neighborhood', Sub);
    Sub := TJSONObject.Create;
    Sub.AddPair('name', Cidade);
    Result.AddPair('city', Sub);
    Sub := TJSONObject.Create;
    Sub.AddPair('id', Uf);
    Result.AddPair('state', Sub);
  finally
    Obj.Free;
  end;
end;

procedure TMercadoLivreClient.SendInvoiceXml(const PackId, ShipmentId, XmlText: string);
var
  Url: string;
  Source: TStringStream;
  MP: TMultipartFormData;
  Resp: IHTTPResponse;
begin
  if (Trim(PackId) <> '') and (Trim(PackId) <> 'null') then
    Url := 'https://api.mercadolibre.com/packs/' + TNetEncoding.URL.Encode(PackId) + '/fiscal_documents'
  else if (Trim(ShipmentId) <> '') and (Trim(ShipmentId) <> 'null') then
    Url := 'https://api.mercadolibre.com/shipments/' + TNetEncoding.URL.Encode(ShipmentId) + '/invoice_data?siteId=' + FConfig.SiteId
  else
    raise Exception.Create('Pedido sem pack_id/shipment_id para envio de NF-e');

  if (Trim(PackId) <> '') and (Trim(PackId) <> 'null') then
  begin
    // pack/fiscal_documents exige multipart/form-data, com o XML enviado como arquivo
    MP := TMultipartFormData.Create;
    Source := TStringStream.Create(XmlText, TEncoding.UTF8);
    try
      MP.AddStream('fiscal_document', Source, 'nfe.xml', 'application/xml');
      Resp := FHttp.Post(Url, MP, nil,
        [TNameValuePair.Create('Authorization', AuthHeader)]);
    finally
      MP.Free;
      Source.Free;
    end;
  end
  else
  begin
    Source := TStringStream.Create(XmlText, TEncoding.UTF8);
    try
      Resp := FHttp.Post(Url, Source, nil,
        [TNameValuePair.Create('Authorization', AuthHeader),
         TNameValuePair.Create('Content-Type', 'application/xml')]);
    finally
      Source.Free;
    end;
  end;

  if (Resp.StatusCode < 200) or (Resp.StatusCode > 299) then
    raise Exception.CreateFmt('Envio de NF-e ao Mercado Livre retornou %d: %s',
      [Resp.StatusCode, Resp.ContentAsString(TEncoding.UTF8)]);

  FLog.Info('NF-e enviada ao Mercado Livre');
end;

end.

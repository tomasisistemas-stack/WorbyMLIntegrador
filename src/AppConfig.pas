unit AppConfig;

interface

uses
  System.SysUtils,
  System.IniFiles,
  System.IOUtils;

type
  TAppConfig = record
    ConfigFileName: string;
    PgHost: string;
    PgPort: Integer;
    PgDatabase: string;
    PgUser: string;
    PgPassword: string;
    SiteId: string;
    SellerId: string;
    ClientId: string;
    ClientSecret: string;
    RedirectUri: string;
    AccessToken: string;
    RefreshToken: string;
    TokenExpiresAt: TDateTime;
    PollIntervalMs: Integer;
    ImportarPedidos: Boolean;
    EnviarNotas: Boolean;
    CodEmpresa: Integer;
    CodRepresentante: Integer;
    CodFop: Integer;
    CodPrazoPgto: Integer;
    ProdutoPadrao: Integer;
    LogPath: string;

    class function Load(const FileName: string): TAppConfig; static;
    procedure SaveMercadoLivreToken(const NewAccessToken, NewRefreshToken: string; const NewExpiresAt: TDateTime);
  end;

implementation

class function TAppConfig.Load(const FileName: string): TAppConfig;
var
  Ini: TIniFile;
  FullPath: string;
begin
  FullPath := TPath.GetFullPath(FileName);
  Ini := TIniFile.Create(FullPath);
  try
    Result.ConfigFileName := FullPath;
    Result.PgHost := Ini.ReadString('postgres', 'host', '127.0.0.1');
    Result.PgPort := Ini.ReadInteger('postgres', 'port', 5432);
    Result.PgDatabase := Ini.ReadString('postgres', 'database', 'orbi_teste');
    Result.PgUser := Ini.ReadString('postgres', 'user', 'postgres');
    Result.PgPassword := Ini.ReadString('postgres', 'password', '');

    Result.SiteId := Ini.ReadString('mercadolivre', 'site_id', 'MLB');
    Result.SellerId := Ini.ReadString('mercadolivre', 'seller_id', '');
    Result.ClientId := Ini.ReadString('mercadolivre', 'client_id', '');
    Result.ClientSecret := Ini.ReadString('mercadolivre', 'client_secret', '');
    Result.RedirectUri := Ini.ReadString('mercadolivre', 'redirect_uri', '');
    Result.AccessToken := Ini.ReadString('mercadolivre', 'access_token', '');
    Result.RefreshToken := Ini.ReadString('mercadolivre', 'refresh_token', '');
    Result.TokenExpiresAt := StrToDateTimeDef(Ini.ReadString('mercadolivre', 'token_expires_at', ''), 0);

    Result.PollIntervalMs := Ini.ReadInteger('worker', 'poll_interval_ms', 60000);
    Result.ImportarPedidos := SameText(Ini.ReadString('worker', 'importar_pedidos', 'S'), 'S');
    Result.EnviarNotas := SameText(Ini.ReadString('worker', 'enviar_notas', 'S'), 'S');
    Result.CodEmpresa := Ini.ReadInteger('worker', 'cod_empresa', 1);
    Result.CodRepresentante := Ini.ReadInteger('worker', 'cod_representante', 1);
    Result.CodFop := Ini.ReadInteger('worker', 'cod_fop', 1);
    Result.CodPrazoPgto := Ini.ReadInteger('worker', 'cod_prazo_pgto', 1);
    Result.ProdutoPadrao := Ini.ReadInteger('worker', 'produto_padrao', 0);

    Result.LogPath := Ini.ReadString('paths', 'log_path', TPath.Combine(TPath.GetDirectoryName(FullPath), 'logs'));
  finally
    Ini.Free;
  end;
end;

procedure TAppConfig.SaveMercadoLivreToken(const NewAccessToken, NewRefreshToken: string; const NewExpiresAt: TDateTime);
var
  Ini: TIniFile;
begin
  if Trim(ConfigFileName) = '' then
    Exit;

  Ini := TIniFile.Create(ConfigFileName);
  try
    Ini.WriteString('mercadolivre', 'access_token', NewAccessToken);
    if Trim(NewRefreshToken) <> '' then
      Ini.WriteString('mercadolivre', 'refresh_token', NewRefreshToken);
    Ini.WriteString('mercadolivre', 'token_expires_at', DateTimeToStr(NewExpiresAt));
  finally
    Ini.Free;
  end;
end;

end.

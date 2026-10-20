unit Db;

interface

uses
  System.SysUtils,
  FireDAC.Comp.Client,
  FireDAC.Phys.PG,
  FireDAC.Phys.PGDef,
  FireDAC.Stan.Def,
  FireDAC.Stan.Async,
  FireDAC.Stan.Pool,
  FireDAC.Stan.Intf,
  FireDAC.UI.Intf,
  FireDAC.VCLUI.Wait,
  FireDAC.Comp.UI,
  AppConfig;

type
  TDb = class
  private
    FConfig: TAppConfig;
    FConnection: TFDConnection;
    FDriver: TFDPhysPgDriverLink;
    FWait: TFDGUIxWaitCursor;
  public
    constructor Create(const Config: TAppConfig);
    destructor Destroy; override;
    procedure Connect;
    property Connection: TFDConnection read FConnection;
  end;

implementation

constructor TDb.Create(const Config: TAppConfig);
begin
  FConfig := Config;
  FDriver := TFDPhysPgDriverLink.Create(nil);
  FWait := TFDGUIxWaitCursor.Create(nil);
  FConnection := TFDConnection.Create(nil);
end;

destructor TDb.Destroy;
begin
  FConnection.Free;
  FWait.Free;
  FDriver.Free;
  inherited;
end;

procedure TDb.Connect;
begin
  FConnection.Connected := False;
  FConnection.Params.Clear;
  FConnection.Params.DriverID := 'PG';
  FConnection.Params.Add('Server=' + FConfig.PgHost);
  FConnection.Params.Add('Port=' + IntToStr(FConfig.PgPort));
  FConnection.Params.Add('Database=' + FConfig.PgDatabase);
  FConnection.Params.Add('User_Name=' + FConfig.PgUser);
  FConnection.Params.Add('Password=' + FConfig.PgPassword);
  FConnection.LoginPrompt := False;
  FConnection.Connected := True;
end;

end.

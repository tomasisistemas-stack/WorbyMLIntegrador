program WorbyMLIntegrador;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  AppConfig in 'AppConfig.pas',
  Logger in 'Logger.pas',
  Db in 'Db.pas',
  MercadoLivreClient in 'MercadoLivreClient.pas',
  MercadoLivreRepository in 'MercadoLivreRepository.pas',
  Worker in 'Worker.pas';

var
  Config: TAppConfig;
  Log: TLogger;
  Db: TDb;
  Client: TMercadoLivreClient;
  Repo: TMercadoLivreRepository;
  Worker: TWorker;
begin
  try
    Config := TAppConfig.Load('config.ini');
    Log := TLogger.Create(Config.LogPath);
    try
      Log.Info('WorbyMLIntegrador iniciado');
      Db := TDb.Create(Config);
      try
        Db.Connect;
        Client := TMercadoLivreClient.Create(Config, Log);
        try
          Repo := TMercadoLivreRepository.Create(Db.Connection, Config, Log);
          try
            Worker := TWorker.Create(Config, Log, Client, Repo);
            try
              Worker.Run;
            finally
              Worker.Free;
            end;
          finally
            Repo.Free;
          end;
        finally
          Client.Free;
        end;
      finally
        Db.Free;
      end;
    finally
      Log.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln(FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + ' ERRO: ' + E.Message);
      Halt(1);
    end;
  end;
end.

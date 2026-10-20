unit Logger;

interface

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils;

type
  TLogger = class
  private
    FPath: string;
    procedure WriteLine(const Level, Msg: string);
  public
    constructor Create(const Path: string);
    procedure Info(const Msg: string);
    procedure Error(const Msg: string);
  end;

implementation

constructor TLogger.Create(const Path: string);
begin
  FPath := Path;
  ForceDirectories(FPath);
end;

procedure TLogger.WriteLine(const Level, Msg: string);
var
  Line, FileName: string;
begin
  Line := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + ' ' + Level + ': ' + Msg;
  Writeln(Line);
  FileName := TPath.Combine(FPath, FormatDateTime('yyyymmdd', Date) + '.log');
  TFile.AppendAllText(FileName, Line + sLineBreak, TEncoding.UTF8);
end;

procedure TLogger.Info(const Msg: string);
begin
  WriteLine('INFO', Msg);
end;

procedure TLogger.Error(const Msg: string);
begin
  WriteLine('ERRO', Msg);
end;

end.

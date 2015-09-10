program Proxy;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  System.SysUtils,
  System.IniFiles,
  System.Classes,
  WinApi.Windows,
  IdHTTP;

type
  // Буфер чтения с COM-порта
  TBuffer = array[0..20] of byte;
  // Настройки
  TSettings = Record
    Port: PWideChar;
    Speed: integer;
    Timeout: integer;
    Host: string;
  end;

type
  TCallable = procedure;

const
  CR = 13;

var
  CommHandle, CommThread: THandle;
  INIFile: TINIFile;
  Settings: TSettings;
  numberOfUsers: integer = 0;

function GetConsoleWindow: HWND; stdcall; external kernel32;  
function WriteComm(Data: string): DWORD; forward;

// Формирует URL для выполнения запроса
function MakeURL(const Action: string; Params: string = ''): string;
var
  URL: string;
begin
  URL := 'http://' + Settings.Host + '/' + Action;
  if (Length(Params) > 0) then
    begin
      URL := URL + '?tag=' + Params
    end;
  Result := URL;
end;

// Отправляет количество пользователей
procedure SendNumberOfUsers();
begin
  WriteComm('USERS ' + IntToStr(numberOfUsers));
end;

// Выполняет HTTP-запрос к серверу
function HTTPRequest(const Action: string; Params: string = ''): string;
var
  HTTP: TIdHTTP;
  Response, URL: string;
begin
  HTTP := TIdHTTP.Create(nil);
  URL := MakeURL(Action, Params);
  try
    try
      HTTP.HandleRedirects := true;
      HTTP.ConnectTimeout := Settings.Timeout;
      Response := HTTP.Get(URL);
      Result := Response;
    except
      on E: EIdHTTPProtocolException do
        begin
          Writeln(E.ErrorCode, ': ', E.Message);
          Writeln(E.ErrorMessage);
        end;
      on E: Exception do
        Writeln(E.ClassName, ': ', E.Message);
    end;
  finally
    HTTP.Free;
  end;
end;

// Интерпретирует и выполняет комманду полученую от Arduino
procedure RunCommand(Command: string);
var
  Params: TStrings;
  Action: string;
  Response: string;
  I: integer;
begin
  Params := TStringList.Create;
  ExtractStrings([' '], [], PChar(Command), Params);
  if (Params.Count > 0) then
    begin
      if (Params[0] = 'CHECK') then
        begin
          Action := 'check.php';
          if (Params.Count > 1) then
            begin
              Response := HTTPRequest(Action, Params[1]);
              WriteLn(Params[1] + ' - ' + Response);
            end
          else
            begin
              Response := HTTPRequest(Action);
            end;
          WriteComm('ACCESS ' + Response);
        end
      else if (Params[0] = 'PRINT') then
        begin
          for I := 1 to Length(Params[1]) do
            begin
              Write(Params[1][I]);
            end;
          WriteLn;
        end;
    end;
end;

// Читает данные из COM-порта
procedure ReadComm();
var
  Buffer: TBuffer;
  TransMask: Cardinal;
  COMStat: TCOMStat;
  Overlapped: TOverlapped;
  Errors: DWORD;
  i: integer;
  Command: string;
begin
  while true do
    begin
      TransMask := 0;
      Command := '';
      WaitCommEvent(CommHandle, TransMask, @Overlapped);
      if ((TransMask and EV_RXFLAG) = EV_RXFLAG) then
        begin
          ClearCommError(CommHandle, Errors, @COMStat);
          ReadFile(CommHandle, Buffer, COMStat.cbInQue, COMStat.cbInQue, @Overlapped);
          for i := 0 to Length(Buffer) do
            begin
              if Buffer[i] = CR then
                begin
                  break;
                end;
              Command := Command + Char(Buffer[i]);
            end;
          RunCommand(Command);
        end;
    end;
  FlushFileBuffers(CommHandle);
end;

// Отправляет данные в COM-порт
function WriteComm(Data: string): DWORD;
var
  BytesWritten: DWORD;
  EndChar: Char;
  I: integer;
  Symbol: byte;
begin
  EndChar := Char(CR);
  Result := 0;
  PurgeComm(CommHandle, PURGE_TXABORT or PURGE_RXABORT or PURGE_TXCLEAR or PURGE_RXCLEAR);
  for I := 1 to Length(Data) do
    begin
      Symbol := Ord(Data[i]);
      WriteFile(CommHandle, Symbol, 1, BytesWritten, nil);
      Result := Result + BytesWritten;
    end;
  WriteFile(CommHandle, EndChar, 1, BytesWritten, nil);
  if BytesWritten <> 1 then
    begin
      Result := 0;
    end;
  FlushFileBuffers(CommHandle);
end;

// Инициализирует COM-порт
function PortInit(ComPort: PWideChar; Baud, Parity, CountBit, StopBit: integer; onInit: TCallable): THandle;
var
  ThreadID: DWORD;
  DCB: TDCB;
  CommTimeouts: TCommTimeouts;
begin
  CommHandle := CreateFile(ComPort, GENERIC_WRITE or GENERIC_READ, 0, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  if (CommHandle = INVALID_HANDLE_VALUE) then
    begin
      raise Exception.Create('Unable to open port');
    end;
  SetCommMask(CommHandle, EV_RXFLAG);
  GetCommState(CommHandle, DCB);
  with DCB do
    begin
      BaudRate := Baud;
      Parity := Parity;
      ByteSize := CountBit;
      StopBits := StopBit;
      EvtChar := Char(CR);
    end;
  SetCommState(CommHandle, DCB);
  with CommTimeouts do
    begin
      ReadIntervalTimeout := 4;
      ReadTotalTimeoutMultiplier := 8;
      ReadTotalTimeoutConstant := 1000;
      WriteTotalTimeoutMultiplier := 0;
      WriteTotalTimeoutConstant := 0;
    end;
  SetCommTimeouts(CommHandle, CommTimeouts);
  SetupComm(CommHandle, 2048, 2048);
  Result := BeginThread(nil, 0, @ReadComm, nil, 0, ThreadID);
  onInit();
end;

// Выполняет загрузку настроек из INI-файла
procedure LoadSettings;
begin
  INIFile := TINIFile.Create(ExtractFilePath(ParamStr(0)) + 'settings.ini');
  with Settings do
    begin
      Port := PWideChar(WideString(INIFile.ReadString('COM', 'port', 'COM1')));
      Speed := INIFile.ReadInteger('COM', 'speed', 9600);
      Host := INIFile.ReadString('Server', 'host', 'localhost');
      Timeout := INIFile.ReadInteger('Server', 'timeout', 5000);
    end;
end;

begin
  try
    try
      begin
        while not ((numberOfUsers >= 1) and (numberOfUsers <= 4)) do
          begin
            Write('Enter the number of users: ');
            ReadLn(numberOfUsers);
          end;
        LoadSettings();
        CommThread := PortInit(Settings.Port, Settings.Speed, 0, 8, 1, @SendNumberOfUsers);
        ReadLn;
      end;
    except
      on E: Exception do
        WriteLn(E.ClassName, ': ', E.Message);
    end;
  finally
    TerminateThread(CommThread, 0);
    CloseHandle(CommHandle);
    INIFile.Free();
  end;
end.

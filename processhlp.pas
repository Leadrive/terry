unit processhlp;

{$mode delphi}

interface

uses Windows, jwaWindows, SysUtils, Classes, Forms, Dialogs, Syncobjs,
  toolu, declu;

type
  PFPList = ^TFPList;

  TWinEnumData = record
    wincount: integer;
    pList: PFPList;
  end;
  PWinEnumData = ^TWinEnumData;

  __QueryFullProcessImageName = function(hProcess: HANDLE; dwFlags: dword; lpExeName: PAnsiChar; var lpdwSize: dword): boolean; stdcall;

  {TRunThread}

  TRunThread = class(TThread)
  private
    exename: string;
    params: string;
    dir: string;
    showcmd: integer;
  protected
    procedure Execute; override;
  public
    constructor Create;
    procedure exec(Aexename, Aparams, Adir: string; Ashowcmd: integer);
  end;

  {TProcessHelper}

  TProcessHelper = class(TObject)
  private
    FReady: boolean;
    crsection: TCriticalSection;
    proc_list: TStrings; // process + PID
    proc_full_list: TStrings; // process full module name + PID
    win_list: TFPList; // app windows
    FWindowsCount: integer;
    FWindowsCountChanged: boolean;
    hKernel32: HMODULE;
    queryFullProcessImageName: __QueryFullProcessImageName;
    // processes //
    RunThread: TRunThread;
    function IndexOf(Name: string): integer;
    function IndexOfFullName(Name: string): integer;
    function IndexOfPID(pid: dword): integer;
    function IndexOfPIDFullName(pid: dword): integer;
    function GetName(index: integer): string;
    function GetFullName(index: integer): string;
    function GetFullNameByPID(pid: uint): string;
  public
    property Ready: boolean read FReady;
    property WindowsCountChanged: boolean read FWindowsCountChanged;
    // //
    constructor Create;
    destructor Destroy; override;
    // processes //
    procedure EnumProc;
    procedure Kill(Name: string);
    function Exists(Name: string): boolean;
    function FullNameExists(Name: string): boolean;
    // run processes //
    procedure Run(exename, params, dir: string; showcmd: integer);
    procedure RunAsUser(exename, params, dir: string; showcmd: integer);
    // windows //
    function GetWindowText(h: THandle): string;
    procedure ActivateWindow(h: THandle);
    function ActivateProcessMainWindow(ProcessName: string; h: THandle; ItemRect: windows.TRect; Edge: integer): boolean;
    procedure EnumAppWindows;
    function GetAppWindowsCount: integer;
    function GetAppWindowHandle(index: integer): THandle;
    function GetAppWindowIndex(h: THandle): integer;
    function GetAppWindowProcessName(h: THandle): string;
    function GetAppWindowProcessFullName(h: THandle): string;
    function GetAppWindowClassName(h: THandle): string;
  end;

var
  ProcessHelper: TProcessHelper;

implementation
//------------------------------------------------------------------------------
constructor TProcessHelper.Create;
begin
  FReady := false;
  inherited Create;
  crsection := TCriticalSection.Create;
  proc_list := TStringList.Create;
  proc_full_list := TStringList.Create;
  win_list := TFPList.Create;
  FWindowsCount := 0;
  FWindowsCountChanged := false;
  RunThread := TRunThread.Create;

  @QueryFullProcessImageName := nil;
  if IsWindowsVista then
  begin
    hKernel32 := LoadLibrary('kernel32.dll');
    if hKernel32 <> 0 then @QueryFullProcessImageName := GetProcAddress(hKernel32, 'QueryFullProcessImageNameA');
  end;

  FReady := assigned(crsection) and assigned(proc_list) and assigned(win_list);
end;
//------------------------------------------------------------------------------
destructor TProcessHelper.Destroy;
begin
  FreeLibrary(hKernel32);
  RunThread.terminate;
  proc_list.free;
  proc_full_list.free;
  win_list.free;
  crsection.free;
  inherited;
end;
//------------------------------------------------------------------------------
//
//
//
// functions to work with processes
//
//
//
//------------------------------------------------------------------------------
procedure TProcessHelper.EnumProc;
var
  snap: HANDLE;
  f: bool;
  lp: TProcessEntry32;
  i: integer;
begin
  crsection.Acquire;
  try
    if not FReady then exit;
    proc_list.Clear;
    snap := CreateToolhelp32Snapshot(2, GetCurrentProcessId);
    if snap < 32 then exit;
    lp.dwSize := sizeof(lp);
    f := Process32First(snap, lp);
    while longint(f) <> 0 do
    begin
      proc_list.AddObject(AnsiLowerCase(lp.szExeFile), TObject(lp.th32ProcessID));
      if proc_full_list.IndexOfObject(tobject(lp.th32ProcessID)) < 0 then
        proc_full_list.AddObject(AnsiLowerCase(GetFullNameByPID(lp.th32ProcessID)), TObject(lp.th32ProcessID));
      f := Process32Next(snap, lp);
    end;
    CloseHandle(snap);

    // delete non-existing //
    i := proc_full_list.Count - 1;
    while i >= 0 do
    begin
      if proc_list.IndexOfObject(proc_full_list.Objects[i]) < 0 then proc_full_list.Delete(i);
      dec(i);
    end;
  finally
    crsection.Leave;
  end;
end;
//------------------------------------------------------------------------------
procedure TProcessHelper.Kill(Name: string);
var
  hProc: HANDLE;
begin
  if not FReady then exit;
  EnumProc;
  Name := AnsiLowerCase(Name);
  if proc_list.indexof(Name) < 0 then exit;
  hProc := OpenProcess(PROCESS_TERMINATE, true, dword(proc_list.Objects[proc_list.indexof(Name)]));
  TerminateProcess(hProc, 0);
end;
//------------------------------------------------------------------------------
function TProcessHelper.Exists(Name: string): boolean;
begin
  result := IndexOf(Name) >= 0;
end;
//------------------------------------------------------------------------------
function TProcessHelper.FullNameExists(Name: string): boolean;
begin
  result := IndexOfFullName(AnsiLowerCase(Name)) >= 0;
end;
//------------------------------------------------------------------------------
function TProcessHelper.IndexOf(Name: string): integer;
begin
  result := proc_list.IndexOf(AnsiLowerCase(Name));
end;
//------------------------------------------------------------------------------
function TProcessHelper.IndexOfFullName(Name: string): integer;
begin
  result := proc_full_list.IndexOf(AnsiLowerCase(Name));
end;
//------------------------------------------------------------------------------
function TProcessHelper.IndexOfPID(pid: dword): integer;
begin
  result := proc_list.IndexOfObject(TObject(pid));
end;
//------------------------------------------------------------------------------
function TProcessHelper.IndexOfPIDFullName(pid: dword): integer;
begin
  result := proc_full_list.IndexOfObject(TObject(pid));
end;
//------------------------------------------------------------------------------
function TProcessHelper.GetName(index: integer): string;
begin
  result := '';
  if (index >= 0) and (index < proc_list.Count) then result := proc_list.strings[index];
end;
//------------------------------------------------------------------------------
function TProcessHelper.GetFullName(index: integer): string;
begin
  result := '';
  if (index >= 0) and (index < proc_full_list.Count) then result := proc_full_list.strings[index];
end;
//------------------------------------------------------------------------------
function TProcessHelper.GetFullNameByPID(pid: uint): string;
var
  hProcess: HANDLE;
  size: dword;
  buff: array [0..MAX_PATH - 1] of AnsiChar;
begin
  result := '';
  hProcess := OpenProcess(PROCESS_QUERY_INFORMATION or PROCESS_VM_READ, false, pid);
  if hProcess > 32 then
  begin
      size := MAX_PATH;
      ZeroMemory(@buff, MAX_PATH);

      if assigned(QueryFullProcessImageName) then
      begin
          QueryFullProcessImageName(hProcess, 0, buff, size);
          GetLongPathName(buff, buff, MAX_PATH);
          result := strpas(pchar(@buff));
      end;

      if result = '' then
      begin
        GetModuleFileNameEx(hProcess, 0, buff, MAX_PATH);
        result := strpas(pchar(@buff));
      end;

      CloseHandle(hProcess);
  end;
end;
//------------------------------------------------------------------------------
//
//
//
// functions to run processes
//
//
//
//------------------------------------------------------------------------------
procedure TProcessHelper.RunAsUser(exename, params, dir: string; showcmd: integer);
var
  params_, dir_: pchar;
begin
  params_ := nil;
  dir_ := nil;
  if params <> '' then params_ := PChar(UnzipPath(params));
  if dir <> '' then dir_ := PChar(UnzipPath(dir));
  shellexecute(0, 'runas', pchar(UnzipPath(exename)), params_, dir_, showcmd);
end;
//------------------------------------------------------------------------------
procedure TProcessHelper.Run(exename, params, dir: string; showcmd: integer);
begin
  RunThread.exec(exename, params, dir, showcmd);
  if Assigned(RunThread.FatalException) then raise RunThread.FatalException;
end;
//------------------------------------------------------------------------------
//
//
// runner thread
//
//
//------------------------------------------------------------------------------
constructor TRunThread.Create;
begin
  FreeOnTerminate := true;
  inherited Create(true);
end;
//------------------------------------------------------------------------------
procedure TRunThread.exec(Aexename, Aparams, Adir: string; Ashowcmd: integer);
begin
  exename := Aexename;
  params := Aparams;
  dir := Adir;
  showcmd := Ashowcmd;
  Resume;
end;
//------------------------------------------------------------------------------
procedure TRunThread.Execute;
var
  params_, dir_: pchar;
  err: cardinal;
begin
  while not Terminated do
  begin
    params_ := nil;
    dir_ := nil;
    if params <> '' then params_ := PChar(params);
    if dir <> '' then dir_ := PChar(dir);
    err := shellexecute(application.mainform.handle, nil, pchar(exename), params_, dir_, showcmd);
    Suspend;
  end;
end;
//------------------------------------------------------------------------------
//
//
//
// functions to work with process windows
//
//
//
//------------------------------------------------------------------------------
function CmpWindows(Item1, Item2: Pointer): Integer;
var
  pid1, pid2: dword;
begin
  GetWindowThreadProcessId(THandle(Item1), @pid1);
  GetWindowThreadProcessId(THandle(Item2), @pid2);
  result := 0;
  if pid1 > pid2 then result := -1;
  if pid1 < pid2 then result := 1;
  if pid1 = pid2 then
  begin
    if THandle(Item1) > THandle(Item2) then result := -1;
    if THandle(Item1) < THandle(Item2) then result := 1;
  end;
end;
//------------------------------------------------------------------------------
function EnumWProc(h: THandle; l: LPARAM): bool; stdcall;
var
  exstyle: PtrUInt;
  ch: array [0..10] of char;
begin
  result := true;
  inc(PWinEnumData(l)^.wincount);

  if IsWindowVisible(h) then
  begin
    exstyle := GetWindowLongPtr(h, GWL_EXSTYLE);
    if exstyle and WS_EX_APPWINDOW = 0 then
    begin
      if GetWindow(h, GW_OWNER) <> THandle(0) then exit;
      if exstyle and WS_EX_TOOLWINDOW = WS_EX_TOOLWINDOW then exit;
      if windows.GetWindowText(h, ch, 10) < 1 then exit;
    end;

    PWinEnumData(l)^.pList^.Add(pointer(h));
  end;
end;
//------------------------------------------------------------------------------
procedure TProcessHelper.EnumAppWindows;
var
  data: TWinEnumData;
begin
  crsection.Acquire;
  try
    self.FWindowsCountChanged := false;
    if not FReady then exit;

    win_list.Clear;
    data.wincount := 0;
    data.pList := @win_list;
    EnumWindows(@EnumWProc, LPARAM(@data));
    win_list.Sort(CmpWindows);

    FWindowsCountChanged := data.wincount <> FWindowsCount;
    FWindowsCount := data.wincount;
  finally
    crsection.Leave;
  end;
end;
//------------------------------------------------------------------------------
function TProcessHelper.GetWindowText(h: THandle): string;
var
  win_name: array [0..255] of char;
begin
  windows.GetWindowText(h, @win_name[0], 255);
  result := strpas(pchar(@win_name[0]));
end;
//------------------------------------------------------------------------------
procedure TProcessHelper.ActivateWindow(h: THandle);

function ZOrderIndex(hWnd: uint): integer;
var
  index: integer;
  h: THandle;
begin
  result := 0;
  index := 0;
	h := FindWindow('Progman', nil);
	while (h <> 0) and (h <> hWnd) do
	begin
		inc(index);
		h := GetWindow(h, GW_HWNDPREV);
	end;
	result := index;
end;

function WindowOnTop(wnd: THandle): boolean;
var
  i, index: integer;
  h: THandle;
begin
  result := true;
  index := ZOrderIndex(wnd);
  i := 0;
  while i < win_list.count do
  begin
    h := THandle(win_list.items[i]);
    if h <> wnd then
      if IsWindowVisible(h) and not IsIconic(h) then
        if ZOrderIndex(h) > index then
        begin
          result := false;
          break;
        end;
    inc(i);
  end;
end;

begin
  if IsWindowVisible(h) and not IsIconic(h) then
  begin
    if WindowOnTop(h) then
      PostMessage(h, WM_SYSCOMMAND, SC_MINIMIZE, 0)
    else
    begin
      AllowSetForeground(h);
      SetForegroundWindow(h);
    end;
  end else begin
    PostMessage(h, WM_SYSCOMMAND, SC_RESTORE, 0);
    AllowSetForeground(h);
    SetForegroundWindow(h);
  end;
end;
//------------------------------------------------------------------------------
// ProcessName - path and file name
// h - item window handle
// ItemRect - screen rect of item to calc the position of a popup menu
// Edge - edge of screen the item is docked at
function TProcessHelper.ActivateProcessMainWindow(ProcessName: string; h: THandle; ItemRect: windows.TRect; Edge: integer): boolean;
var
  i: integer;
  hMenu, menu_align: cardinal;
  wnd: THandle;
  wtpid: dword;
  wlist: TFPList;
begin
  result := false;

  EnumProc;

  if FullNameExists(ProcessName) then
  begin

    EnumAppWindows;
    wlist := TFPList.Create;
    i := 0;
    while i < win_list.count do
    begin
      wnd := THandle(win_list.items[i]);
      GetWindowThreadProcessId(wnd, @wtpid);
      if GetFullName(IndexOfPIDFullName(wtpid)) = AnsiLowerCase(ProcessName) then wlist.Add(pointer(wnd));
      inc(i);
    end;
    result := wlist.Count > 0;

    if wlist.Count = 1 then // in case of only one window //
    begin
      ActivateWindow(THandle(wlist.items[0]));
    end
    else if result then // in case of several windows //
    begin

      hMenu := CreatePopupMenu;
      i := 0;
      while i < wlist.Count do
      begin
        AppendMenu(hMenu, MF_STRING, $100 + i, pchar(GetWindowText(THandle(wlist.items[i]))));
        inc(i);
      end;
      AppendMenu(hMenu, MF_SEPARATOR, 0, '-');
      AppendMenu(hMenu, MF_STRING, $2, 'Run program');

      menu_align := TPM_LEFTALIGN + TPM_TOPALIGN;
      case Edge of
        0: ItemRect.left := ItemRect.right;
        1: ItemRect.top := ItemRect.bottom;
        2: menu_align := TPM_RIGHTALIGN + TPM_TOPALIGN;
        3: menu_align := TPM_LEFTALIGN + TPM_BOTTOMALIGN;
      end;
      i := integer(TrackPopupMenuEx(hMenu, menu_align + TPM_RIGHTBUTTON + TPM_RETURNCMD, ItemRect.Left, ItemRect.Top, h, nil));
      DestroyMenu(hMenu);

      if i = $2 then result := false
      else if i >= $100 then ActivateWindow(THandle(wlist.items[i - $100]));

    end; // end case of several windows //

    wlist.free;
  end;
end;
//------------------------------------------------------------------------------
function TProcessHelper.GetAppWindowsCount: integer;
begin
  result := win_list.count;
end;
//------------------------------------------------------------------------------
function TProcessHelper.GetAppWindowHandle(index: integer): THandle;
begin
  result := THandle(win_list.items[index]);
end;
//------------------------------------------------------------------------------
function TProcessHelper.GetAppWindowIndex(h: THandle): integer;
begin
  result := win_list.IndexOf(pointer(h));
end;
//------------------------------------------------------------------------------
function TProcessHelper.GetAppWindowProcessName(h: THandle): string;
var
  wtpid: dword;
begin
  GetWindowThreadProcessId(h, @wtpid);
  result := GetName(IndexOfPID(wtpid));
end;
//------------------------------------------------------------------------------
function TProcessHelper.GetAppWindowProcessFullName(h: THandle): string;
var
  wtpid: dword;
begin
  GetWindowThreadProcessId(h, @wtpid);
  result := GetFullName(IndexOfPIDFullName(wtpid));
end;
//------------------------------------------------------------------------------
function TProcessHelper.GetAppWindowClassName(h: THandle): string;
var
  cls: array [0..255] of char;
begin
  GetClassName(h, @cls, 255);
  result := strpas(pchar(@cls));
end;
//------------------------------------------------------------------------------
initialization
  ProcessHelper := TProcessHelper.Create;
finalization
  ProcessHelper.free;
end.


//go:build windows

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

// hideWindow stops a console window flashing up for each helper process.
func hideWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_NO_WINDOW}
}

var workerJob windows.Handle

// bindToLauncher puts the worker in a job that Windows closes when the
// launcher exits, so a crashed or updated launcher never leaves a stray
// Python process holding the graphics card.
func bindToLauncher(cmd *exec.Cmd) {
	if workerJob == 0 {
		job, err := windows.CreateJobObject(nil, nil)
		if err != nil {
			return
		}
		info := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
		info.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
		if _, err := windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation,
			uintptr(unsafe.Pointer(&info)), uint32(unsafe.Sizeof(info))); err != nil {
			windows.CloseHandle(job)
			return
		}
		workerJob = job
	}
	handle, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, uint32(cmd.Process.Pid))
	if err != nil {
		return
	}
	defer windows.CloseHandle(handle)
	_ = windows.AssignProcessToJobObject(workerJob, handle)
}

// registerAutostart makes Windows start the server when you sign in. It uses
// the per-user Run key, so no administrator rights are needed.
func registerAutostart() error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	key, _, err := registry.CreateKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Run`, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer key.Close()
	return key.SetStringValue("MynaServer", `"`+exe+`" --background`)
}

func openBrowser(url string) {
	cmd := exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
	hideWindow(cmd)
	_ = cmd.Start()
}

// closeOtherCopies ends every other running MynaServer.exe and returns how
// many there were.
func closeOtherCopies() int {
	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return 0
	}
	defer windows.CloseHandle(snapshot)
	self := uint32(os.Getpid())
	name := "mynaserver.exe"
	if exe, err := os.Executable(); err == nil {
		name = strings.ToLower(filepath.Base(exe))
	}
	closed := 0
	var entry windows.ProcessEntry32
	entry.Size = uint32(unsafe.Sizeof(entry))
	for err = windows.Process32First(snapshot, &entry); err == nil; err = windows.Process32Next(snapshot, &entry) {
		if entry.ProcessID == self || strings.ToLower(windows.UTF16ToString(entry.ExeFile[:])) != name {
			continue
		}
		handle, err := windows.OpenProcess(windows.PROCESS_TERMINATE|windows.SYNCHRONIZE, false, entry.ProcessID)
		if err != nil {
			continue
		}
		if windows.TerminateProcess(handle, 0) == nil {
			_, _ = windows.WaitForSingleObject(handle, 3000)
			closed++
		}
		windows.CloseHandle(handle)
	}
	return closed
}

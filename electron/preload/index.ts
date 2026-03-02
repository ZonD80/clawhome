import { contextBridge, ipcRenderer } from "electron";

try {
  contextBridge.exposeInMainWorld("electronAPI", {
    vmList: () => ipcRenderer.invoke("vm-list"),
    vmCreate: (options: {
      name: string;
      ramMb?: number;
      diskGb?: number;
      ipswPath?: string;
    }) => ipcRenderer.invoke("vm-create", options),
    vmInstallProgress: (vmId: string) => ipcRenderer.invoke("vm-install-progress", vmId),
    vmStart: (vmId: string) => ipcRenderer.invoke("vm-start", vmId),
    vmStop: (vmId: string, force?: boolean) => ipcRenderer.invoke("vm-stop", vmId, force),
    showStopConfirmDialog: () => ipcRenderer.invoke("show-stop-confirm-dialog"),
    vmDelete: (vmId: string) => ipcRenderer.invoke("vm-delete", vmId),
    vmShowConsole: (vmId: string) => ipcRenderer.invoke("vm-show-console", vmId),
    version: () => ipcRenderer.invoke("get-version"),
    checkForUpdates: () => ipcRenderer.invoke("check-for-updates"),
    openClawhomeDir: () => ipcRenderer.invoke("open-clawhome-dir"),
    openExternal: (url: string) => ipcRenderer.invoke("open-external", url),
    showVmExistsDialog: (vmId: string) =>
      ipcRenderer.invoke("show-vm-exists-dialog", vmId),
    showErrorDialog: (message: string) =>
      ipcRenderer.invoke("show-error-dialog", message),
  });
} catch (err) {
  console.error("[ClawHome preload] Failed:", err);
}

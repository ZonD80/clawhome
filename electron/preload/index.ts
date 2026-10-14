import { contextBridge, ipcRenderer } from "electron";

try {
  contextBridge.exposeInMainWorld("electronAPI", {
    vmList: () => ipcRenderer.invoke("vm-list"),
    vmCreate: (options: {
      name: string;
      ramMb?: number;
      diskGb?: number;
      ipswPath?: string;
      guestType?: string;
      imageUrl?: string;
      fmmJson?: string;
      fmmSourcePath?: string;
    }) => ipcRenderer.invoke("vm-create", options),
    lookupBiaRelease: () => ipcRenderer.invoke("lookup-bia-release"),
    pickDiskImage: () => ipcRenderer.invoke("pick-disk-image"),
    loadFmmFile: () => ipcRenderer.invoke("load-fmm-file"),
    checkFmm: (input: {
      provider?: string;
      apiKey?: string;
      model?: string;
      baseUrl?: string;
      ctx?: number;
      chatgpt?: unknown;
      sourcePath?: string;
    }) => ipcRenderer.invoke("check-fmm", input),
    listFmmModels: (input: {
      provider?: string;
      apiKey?: string;
      model?: string;
      baseUrl?: string;
      chatgpt?: unknown;
    }) => ipcRenderer.invoke("fmm-list-models", input),
    signInChatGpt: () => ipcRenderer.invoke("fmm-chatgpt-sign-in"),
    onChatgptStatus: (cb: (status: string) => void) => {
      const listener = (_event: unknown, status: string) => cb(status);
      ipcRenderer.on("fmm-chatgpt-status", listener);
      return () => ipcRenderer.removeListener("fmm-chatgpt-status", listener);
    },
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

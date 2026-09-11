declare module "*.elm" {
  export const Elm: {
    Main: {
      init(options: { node: HTMLElement | null; flags: unknown }): {
        ports: {
          apiRequest_Api_JS: { subscribe(handler: (value: any) => void): void };
          apiResponse_Api_ELM: { send(value: unknown): void };
          uploadAsset_Media_JS: { subscribe(handler: (value: any) => void): void };
          uploadFinished_Media_ELM: { send(value: unknown): void };
          setTheme_Shell_JS: { subscribe(handler: (value: string) => void): void };
          setUnsaved_Editor_JS: { subscribe(handler: (value: boolean) => void): void };
          copyText_Clipboard_JS: { subscribe(handler: (value: string) => void): void };
          openUrl_Download_JS: { subscribe(handler: (value: string) => void): void };
        };
      };
    };
  };
}

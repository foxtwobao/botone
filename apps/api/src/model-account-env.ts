export interface ModelAccountEnv {
  modelAccountConnection?: string;
  modelAccountDefaultModel?: string;
}

export function loadModelAccountEnv(source: NodeJS.ProcessEnv = process.env): ModelAccountEnv {
  return {
    modelAccountConnection: source.MODEL_ACCOUNT_CONNECTION?.trim() || undefined,
    modelAccountDefaultModel: source.PI_DEFAULT_MODEL?.trim() || undefined,
  };
}

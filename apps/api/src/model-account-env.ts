export interface ModelAccountEnv {
  modelAccountConnection?: string;
  executionConnection?: string;
  modelAccountDefaultModel?: string;
}

export function loadModelAccountEnv(source: NodeJS.ProcessEnv = process.env): ModelAccountEnv {
  return {
    ...(source.EXECUTION_CONNECTION?.trim()
      ? { executionConnection: source.EXECUTION_CONNECTION.trim() }
      : {}),
    modelAccountConnection: source.MODEL_ACCOUNT_CONNECTION?.trim() || undefined,
    modelAccountDefaultModel: source.PI_DEFAULT_MODEL?.trim() || undefined,
  };
}

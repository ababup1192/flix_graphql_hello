// 封筒の受け口。URL・ヘッダ・再試行・タイムアウトはここだけが知る。
// Elm 側は { id, kind, path, document, retriable } を渡すだけ。

export type Envelope = {
  id: string;
  kind: string;
  path: string;
  document: string;
  retriable: boolean;
};

export type Reply = {
  id: string;
  kind: string;
  ok: boolean;
  // status は「届いたか」を Elm 側で見分けるのに要る。0 は届かなかった。
  status: number;
  requestId: string | null;
  body: unknown;
};

const TIMEOUT_MS = 20000;
const RETRIES = 2;
const BACKOFF_MS = 200;

// 再試行は「読むだけ」の物に限る。mutation を再試行すると二重に作られる。
async function once(envelope: Envelope): Promise<Reply> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const response = await fetch(envelope.path, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "Content-Type": "application/json",
        "X-Request-Id": envelope.id,
      },
      // 操作名は document に埋めてある（Api.named）。operationName を別に送ると、
      // 名前が食い違った時にサーバが落ちる。
      body: JSON.stringify({ query: envelope.document }),
      signal: controller.signal,
    });
    const requestId = response.headers.get("X-Request-Id");
    let body: unknown = null;
    try {
      body = await response.json();
    } catch {
      body = null;
    }
    return { id: envelope.id, kind: envelope.kind, ok: response.ok, status: response.status, requestId, body };
  } finally {
    clearTimeout(timer);
  }
}

export async function send(envelope: Envelope): Promise<Reply> {
  const attempts = envelope.retriable ? RETRIES + 1 : 1;
  let lastError: unknown = null;
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    try {
      const reply = await once(envelope);
      // 5xx は再試行してよい。4xx は投げ直しても同じ。
      if (reply.ok || reply.body !== null || attempt === attempts - 1) {
        return reply;
      }
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, BACKOFF_MS * (attempt + 1)));
  }
  return {
    id: envelope.id,
    kind: envelope.kind,
    ok: false,
    status: 0,
    requestId: envelope.id,
    body: {
      errors: [
        {
          message: String(lastError ?? "サーバに届きませんでした"),
          extensions: { code: "INTERNAL", requestId: envelope.id },
        },
      ],
    },
  };
}

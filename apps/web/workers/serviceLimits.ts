import { json } from "./crypto";

const READ_LIMIT_ERROR = "Exceeded allowed rows read in Durable Objects free tier.";

export function isDurableObjectsReadLimit(error: unknown): boolean {
  return error instanceof Error && error.message.includes(READ_LIMIT_ERROR);
}

export function durableObjectsReadLimitResponse(requestId?: string): Response {
  const now = new Date();
  const retryAt = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1));
  const retryAfterSeconds = Math.max(1, Math.ceil((retryAt.getTime() - now.getTime()) / 1000));
  const resetTime = new Intl.DateTimeFormat("ko-KR", {
    timeZone: "Asia/Seoul", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hour12: false,
  }).format(retryAt);
  const message = `Cloudflare Durable Objects 무료 일일 읽기 한도에 도달해 동기화가 지연되고 있습니다. 저장 데이터는 유지됩니다. ${resetTime} 이후 자동으로 다시 시도합니다.`;
  return json({
    error: "durable_objects_read_limit",
    message,
    retryAt: retryAt.toISOString(),
    retryAfterSeconds,
    ...(requestId ? { requestId } : {}),
  }, { status: 503, headers: { "Retry-After": String(retryAfterSeconds) } });
}

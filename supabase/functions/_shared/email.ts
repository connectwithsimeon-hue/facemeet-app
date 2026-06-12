function escapeHtml(value: string) {
  return value.replace(/[&<>"']/g, (char) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  }[char] ?? char));
}

export interface TransactionalEmailParams {
  to: string;
  subject: string;
  text: string;
  html?: string;
  from?: string;
}

export async function sendTransactionalEmail(
  params: TransactionalEmailParams,
) {
  const resendApiKey = Deno.env.get("RESEND_API_KEY");
  if (!resendApiKey) {
    console.warn("EMAIL SEND: RESEND_API_KEY not configured");
    return {
      success: false,
      error: "missing_resend_api_key",
    };
  }

  const fromEmail = params.from ||
    Deno.env.get("RESEND_FROM_EMAIL") ||
    "FaceMeet <support@facemeet.app>";
  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${resendApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: fromEmail,
      to: params.to,
      subject: params.subject,
      text: params.text,
      html: params.html,
    }),
  });

  if (!response.ok) {
    const errorText = await response.text();
    console.error("EMAIL SEND: resend failed", {
      status: response.status,
      message: errorText.slice(0, 240),
    });
    return {
      success: false,
      error: "resend_request_failed",
    };
  }

  return { success: true };
}

export function buildSimpleEmailHtml(title: string, paragraphs: string[]) {
  const body = paragraphs
    .map((paragraph) => `<p>${escapeHtml(paragraph)}</p>`)
    .join("");

  return `
    <div style="font-family:Arial,sans-serif;line-height:1.5;color:#16120f;">
      <h2 style="margin:0 0 12px;color:#7c3aed;">${escapeHtml(title)}</h2>
      ${body}
    </div>
  `;
}

export function buildRewardEmailHtml(params: {
  eyebrow: string;
  title: string;
  paragraphs: string[];
  ctaLabel?: string;
  ctaUrl?: string;
  footer?: string;
}) {
  const body = params.paragraphs
    .map((paragraph) =>
      `<p style="margin:0 0 16px;color:#f6ede8;font-size:16px;line-height:1.6;">${
        escapeHtml(paragraph)
      }</p>`
    )
    .join("");

  const cta = params.ctaLabel && params.ctaUrl
    ? `
      <div style="margin:28px 0 8px;">
        <a
          href="${escapeHtml(params.ctaUrl)}"
          style="display:inline-block;background:#ef4e3a;color:#ffffff;text-decoration:none;font-weight:700;font-size:15px;line-height:1;padding:14px 22px;border-radius:999px;"
        >${escapeHtml(params.ctaLabel)}</a>
      </div>
    `
    : "";

  const footer = params.footer
    ? `<p style="margin:28px 0 0;color:#d6c1b9;font-size:13px;line-height:1.5;">${
      escapeHtml(params.footer)
    }</p>`
    : "";

  return `
    <div style="margin:0;padding:32px 16px;background:#090909;">
      <div style="max-width:560px;margin:0 auto;background:#1a0b0a;border:1px solid #5b251d;border-radius:20px;overflow:hidden;">
        <div style="padding:32px 28px 30px;">
          <div style="margin:0 0 18px;color:#ef4e3a;font-size:13px;line-height:1.2;font-weight:700;letter-spacing:0.08em;text-transform:uppercase;">
            ${escapeHtml(params.eyebrow)}
          </div>
          <h1 style="margin:0 0 18px;color:#fff8f4;font-size:28px;line-height:1.2;font-weight:800;">
            ${escapeHtml(params.title)}
          </h1>
          ${body}
          ${cta}
          ${footer}
        </div>
      </div>
    </div>
  `;
}

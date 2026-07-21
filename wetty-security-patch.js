import helmet from 'helmet';
export const policies = (allowIframe) => (req, res, next) => {
    // Patched (upstream wetty 3.2.0 bug): the stock version sets `hsts` and
    // leaves `upgradeInsecureRequests` at helmet's default (both on)
    // unconditionally, even though it already computes `req.protocol` right
    // below to pick ws:// vs wss:// for connect-src. Over plain HTTP (this
    // container has no TLS configured — see supervisord.conf) that
    // combination breaks the page outright: the browser honors
    // upgrade-insecure-requests and silently retries every asset over
    // https://, which nothing here answers, so wetty.js/wetty.css/the
    // websocket all fail and the terminal never renders. HSTS compounds it
    // by caching "always use https for this host" for a year, so it keeps
    // breaking on repeat visits even after fixing the URL. This patch reuses
    // the same `req.protocol` check already present for connectSrc to also
    // drop both directives when serving over plain HTTP, while leaving the
    // original (secure-by-default) behavior untouched if wetty is ever run
    // with --ssl-key/--ssl-cert.
    const isHttp = req.protocol === 'http';
    helmet({
        referrerPolicy: { policy: ['no-referrer-when-downgrade'] },
        contentSecurityPolicy: {
            directives: {
                defaultSrc: ["'self'"],
                scriptSrc: ["'self'", "'unsafe-inline'", "'unsafe-eval'"],
                scriptSrcAttr: ["'unsafe-inline'"],
                styleSrc: ["'self'", "'unsafe-inline'"],
                fontSrc: ["'self'", 'data:'],
                connectSrc: [
                    "'self'",
                    `${isHttp ? 'ws://' : 'wss://'}${req.get('host') ?? ''}`,
                ],
                upgradeInsecureRequests: isHttp ? null : undefined,
            },
        },
        hsts: !isHttp,
        xFrameOptions: allowIframe ? false : { action: 'sameorigin' },
    })(req, res, next);
};

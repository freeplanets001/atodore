export default {
    async fetch(request, env) {
        const url = new URL(request.url);
        const barcode = (url.searchParams.get("barcode") || "").replace(/\D/g, "");

        if (request.method !== "GET") {
            return json({ found: false, error: "method_not_allowed" }, 405, "no-store");
        }

        if (barcode.length < 8) {
            return json({ found: false, error: "invalid_barcode" }, 400, "no-store");
        }

        if (!env.YAHOO_SHOPPING_CLIENT_ID) {
            return json({ found: false, error: "missing_client_id" }, 500, "no-store");
        }

        const hit = await yahooItemSearch({
            clientID: env.YAHOO_SHOPPING_CLIENT_ID,
            parameterName: "jan_code",
            parameterValue: barcode
        }) || await yahooItemSearch({
            clientID: env.YAHOO_SHOPPING_CLIENT_ID,
            parameterName: "query",
            parameterValue: barcode
        });

        const productName = typeof hit?.name === "string" ? hit.name.trim() : "";
        const brand = typeof hit?.brand?.name === "string" ? hit.brand.name.trim() : null;

        if (!productName) {
            return json({ found: false }, 200, "no-store");
        }

        return json({
            found: true,
            productName,
            brand,
            sourceName: "Yahoo!ショッピング"
        }, 200, "public, max-age=86400");
    }
};

async function yahooItemSearch({ clientID, parameterName, parameterValue }) {
    const yahooURL = new URL("https://shopping.yahooapis.jp/ShoppingWebService/V3/itemSearch");
    yahooURL.searchParams.set("appid", clientID);
    yahooURL.searchParams.set(parameterName, parameterValue);
    yahooURL.searchParams.set("results", "1");

    const yahooResponse = await fetch(yahooURL, {
        headers: {
            "User-Agent": "atodore-barcode-proxy/1.0"
        }
    });

    if (!yahooResponse.ok) {
        return null;
    }

    const data = await yahooResponse.json();
    return Array.isArray(data.hits) ? data.hits[0] : null;
}

function json(body, status = 200, cacheControl = "no-store") {
    return new Response(JSON.stringify(body), {
        status,
        headers: {
            "content-type": "application/json; charset=utf-8",
            "cache-control": cacheControl,
            "access-control-allow-origin": "*"
        }
    });
}

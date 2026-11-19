import Foundation

/// 쇼핑 화면을 읽는 스크립트 (D74).
///
/// 내가 "확인해 줘"를 누를 때와, 내가 맡긴 찾기를 맥의 작업이 하는 동안(D75)에만, 검색 결과나 상품 화면에서만 돌린다 (`ShopSite.page`). 페이지의 스크립트와 섞이지 않는 따로 떨어진 곳에서 돈다.
/// 읽기만 한다: 아무것도 누르지 않고, 화면을 고치지 않고, 입력칸의 값을 읽지 않고, 어디에도 보내지 않는다. 읽은 것은 JSON 글 하나로 돌려준다.
///
/// 정확도가 먼저다. 값은 두 번 확인한 것만 넣는다:
/// - 가격: 페이지가 적어 둔 값(상품 정보 JSON, meta)이 **화면에도 그 숫자로, 줄이 그어지지 않은 채** 보일 때만.
///   적어 둔 값이 없으면 화면에서 가장 큰 글씨의 "○○원"이 하나뿐일 때만. 아니면 넣지 않는다 (맥은 "화면에서 읽지 못했어요"라고 답한다)
/// - 원래 가격: 줄이 그어진 가격일 때만
/// - 이름·판매처: 페이지가 적어 둔 값이 화면에 그대로 보일 때 (이름은 그런 것이 없으면 페이지의 대표 제목)
/// - 배송·도착·재고: 화면의 글 한 줄 그대로 (지어내지 않는다)
/// - 옵션: 화면에 나와 있는 고르기 칸(select, 펼친 목록)의 글
/// - 목록: 상품마다 이름과 가격이 화면에 보일 때만, 지금 보는 자리부터 8개.
///   상품으로 가는 링크의 주소도 함께 읽는다 (D75. 이 기기에서 그 상품 화면을 열 때만 쓰고, 맥으로 보내지 않는다).
///   링크는 가까운 데서부터 찾는다 (D77): 이름이 든 링크 → 이름을 감싼 링크 → 페이지가 그 상품에 적어 둔 상품 주소 →
///   그 상품 칸 안의 링크. 어느 상품의 것인지 가릴 수 없으면(한 칸에 상품 주소가 둘) 쓰지 않는다.
///   링크를 못 찾았으면 왜인지도 적는다 (`why`: 둘레에 링크가 없다 `no_anchor`, 링크는 있는데 https 주소가 없다 `no_href`)
///
/// 알고 둘 것: 네이버의 실제 화면 구조는 이 맥의 네트워크에서 재 볼 수 없었다 (접속이 제한됨). 그래서 특정 클래스 이름에 기대지 않고,
/// 널리 쓰는 표준(JSON-LD, meta)과 화면에 보이는 글·글씨 크기로 읽는다. 못 읽으면 비워 둔다.
enum ShopReader {
    /// 스크립트가 도는 곳의 이름 (페이지의 스크립트와 변수를 나누지 않는다)
    static let worldName = "shopReader"

    /// `kind`("product" | "list")를 받아 읽은 것을 JSON 글로 돌려주는 함수의 몸통
    static let script = #"""
    try {
      const body = document.body;
      if (!body) return "{}";
      const norm = (s) => (typeof s === "string" ? s.replace(/\s+/g, " ").trim() : "");
      const lines = (body.innerText || "").split("\n").map(norm).filter((l) => l.length > 0);
      const flat = lines.join(" ");
      const fmt = (n) => n.toLocaleString("en-US");
      const uniq = (v, i, a) => a.indexOf(v) === i;
      const toInt = (v) => {
        if (typeof v === "number") return Number.isInteger(v) && v > 0 ? v : null;
        if (typeof v !== "string") return null;
        const m = v.trim().match(/^(\d{1,3}(?:,\d{3})+|\d+)(?:\.0+)?$/);
        if (!m) return null;
        const n = parseInt(m[1].replace(/,/g, ""), 10);
        return n > 0 ? n : null;
      };
      const isShown = (el) => {
        if (!el || !el.getClientRects().length) return false;
        const st = getComputedStyle(el);
        return st.visibility !== "hidden" && st.display !== "none";
      };
      const isStruck = (el) => {
        for (let e = el, i = 0; e && e !== body && i < 4; e = e.parentElement, i++) {
          if (e.tagName === "DEL" || e.tagName === "S" || e.tagName === "STRIKE") return true;
          const st = getComputedStyle(e);
          if (String(st.textDecorationLine || st.textDecoration || "").indexOf("line-through") >= 0) return true;
        }
        return false;
      };

      // 화면에 보이는 가격: "12,900원" 또는 "12,900" 바로 뒤에 "원"
      const tokens = [];
      (() => {
        const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
        const nodes = [];
        let node;
        while ((node = walker.nextNode()) && nodes.length < 20000) {
          const tag = node.parentElement ? node.parentElement.tagName : "";
          if (tag === "SCRIPT" || tag === "STYLE" || tag === "NOSCRIPT" || tag === "TEMPLATE") continue;
          if (node.nodeValue && /\S/.test(node.nodeValue)) nodes.push(node);
        }
        for (let i = 0; i < nodes.length && tokens.length < 400; i++) {
          const text = norm(nodes[i].nodeValue);
          if (text.length > 16) continue;
          let value = null;
          const whole = text.match(/^(\d{1,3}(?:,\d{3})+|\d+)\s*원$/);
          if (whole) {
            value = toInt(whole[1]);
          } else if (/^(\d{1,3}(?:,\d{3})+|\d{3,})$/.test(text)) {
            const next = i + 1 < nodes.length ? norm(nodes[i + 1].nodeValue) : "";
            if (/^원/.test(next)) value = toInt(text);
          }
          if (value === null) continue;
          const el = nodes[i].parentElement;
          if (!isShown(el)) continue;
          tokens.push({ value: value, struck: isStruck(el), size: parseFloat(getComputedStyle(el).fontSize) || 0, el: el });
        }
      })();
      const inText = (n) => new RegExp("(^|[^0-9,])" + fmt(n) + "\\s*원").test(flat);
      const struckOnScreen = (n) => tokens.some((t) => t.value === n && t.struck);
      // 그 숫자가 화면에 가격으로, 줄이 그어지지 않은 채 보이는지
      const confirmed = (n) => tokens.some((t) => t.value === n && !t.struck) || (inText(n) && !struckOnScreen(n));

      if (kind === "list") {
        const items = [];
        const seen = {};
        // 그 상품으로 가는 링크의 주소 (https만, 최대 6개). 앱이 이 중에서 상품 화면으로 바로 가는 것만 고른다.
        // 주소는 이 기기에만 있고 맥으로 보내지 않는다
        // 상품 화면으로 바로 가는 주소의 꼴: /{가게}/products/{숫자} (어느 호스트를 여는지는 앱이 정한다)
        const shape = /^https:\/\/[^\/?#]+\/[^\/?#]+\/products\/(\d+)(?:[?#]|$)/;
        const here = String(location.href).split("#")[0];
        // 링크의 주소: https만. 이 화면 자신을 가리키는 것(href="#")은 주소가 아니다
        const hrefOf = (a) => {
          let h = "";
          try { h = a && typeof a.href === "string" ? a.href : ""; } catch (e) {}
          return h.indexOf("https://") === 0 && h.length < 2000 && h.split("#")[0] !== here ? h : "";
        };
        const hrefs = (list) => list.map(hrefOf).filter((h) => h);
        // 한 묶음에 상품 주소 꼴인 것이 서로 다른 상품을 가리키면 어느 것이 이 상품인지 알 수 없다: 그 꼴인 것을 뺀다
        const single = (list) => {
          const ids = list.map((h) => { const m = h.match(shape); return m ? m[1] : null; }).filter((x) => x).filter(uniq);
          return ids.length > 1 ? list.filter((h) => !shape.test(h)) : list;
        };
        // 상품 주소 꼴인 것을 앞에 둔다 (6개에서 자를 때 잘리지 않게)
        const pick = (list) => {
          const all = list.filter((h) => h).filter(uniq);
          return all.filter((h) => shape.test(h)).concat(all.filter((h) => !shape.test(h))).slice(0, 6);
        };
        const add = (title, price, mall, links, why) => {
          if (items.length >= 8 || title.length < 4 || seen[title]) return;
          seen[title] = true;
          const item = { title: title.slice(0, 120) };
          if (price) item.price = price;
          if (mall) item.mall = mall.slice(0, 40);
          if (links && links.length) item.links = links;
          else if (why) item.why = why;
          items.push(item);
        };

        // 1) 페이지가 적어 둔 목록: 이름이 화면에 그대로 보이는 것만, 가격도 화면에 보일 때만
        const found = [];
        const data = document.getElementById("__NEXT_DATA__");
        if (data && (data.textContent || "").length < 5000000) {
          try {
            let budget = 60000;
            const walk = (x, depth) => {
              if (!x || typeof x !== "object" || depth > 14 || budget-- <= 0) return;
              if (Array.isArray(x)) { for (const y of x) walk(y, depth + 1); return; }
              const name = typeof x.productTitle === "string" ? x.productTitle : (typeof x.productName === "string" ? x.productName : null);
              if (name !== null) {
                // 그 상품의 객체에 적힌 주소 가운데 상품 주소 꼴인 것 (물음표 뒤는 뗀다: 상품 화면의 주소만 쓴다)
                const urls = [];
                const take = (v) => {
                  if (typeof v !== "string" || v.length >= 2000 || !shape.test(v)) return;
                  const bare = v.split(/[?#]/)[0];
                  if (urls.length < 6 && urls.indexOf(bare) < 0) urls.push(bare);
                };
                for (const k in x) {
                  const v = x[k];
                  take(v);
                  if (v && typeof v === "object" && !Array.isArray(v)) { for (const j in v) take(v[j]); }
                }
                found.push({
                  title: norm(String(name).replace(/<[^>]*>/g, "")),
                  prices: [x.price, x.lowPrice, x.mobilePrice, x.mobileLowPrice].map(toInt).filter((n) => n),
                  mall: typeof x.mallName === "string" ? norm(x.mallName) : "",
                  urls: single(urls)
                });
                return;
              }
              for (const k in x) walk(x[k], depth + 1);
            };
            walk(JSON.parse(data.textContent), 0);
          } catch (e) {}
        }
        if (found.length) {
          const anchors = Array.prototype.slice.call(document.querySelectorAll("a"), 0, 3000)
            .map((a) => ({ el: a, text: norm(a.textContent) + " " + norm((a.querySelector("img") || a).getAttribute("alt") || "") }));
          const shownTitles = found.map((f) => f.title).filter((t) => t.length >= 4 && flat.indexOf(t) >= 0).filter(uniq);
          const skipTag = (tag) => tag === "SCRIPT" || tag === "STYLE" || tag === "NOSCRIPT" || tag === "TEMPLATE";
          // 그 이름이 적힌 가장 안쪽 요소 (보이는 것을 먼저)
          const holder = (title) => {
            let el = null;
            for (let e = body, i = 0; i < 40; i++) {
              let next = null;
              for (const c of e.children) {
                if (skipTag(c.tagName) || norm(c.textContent).indexOf(title) < 0) continue;
                // 화면에 보이는 글로 적힌 것을 고른다 (스크립트에 적힌 이름이나 숨긴 사본이 아니라)
                if (isShown(c) && norm(c.innerText).indexOf(title) >= 0) { next = c; break; }
                if (!next) next = c;
              }
              if (!next) break;
              el = e = next;
            }
            return el;
          };
          // 이름에서 위로 올라가며 그 상품의 칸 안에 있는 링크를 찾는다.
          // 다른 상품의 이름이나 두 가지 가격이 들어오면 그 상품의 칸을 벗어난 것이다: 거기서 멈춘다.
          // 상품 주소 꼴인 링크가 처음 나오는 데(이름에 가장 가까운 데)까지만 본다
          const around = (el, title) => {
            const others = shownTitles.filter((t) => t !== title && title.indexOf(t) < 0);
            const live = tokens.filter((t) => !t.struck);
            let list = [], count = 0, mixed = false;
            for (let e = el, i = 0; e && e !== body && i < 8; e = e.parentElement, i++) {
              const text = norm(e.textContent);
              if (others.some((t) => text.indexOf(t) >= 0)) break;
              if (live.filter((t) => e.contains(t.el)).map((t) => t.value).filter(uniq).length > 1) break;
              const inside = Array.prototype.slice.call(e.querySelectorAll("a[href]"), 0, 40);
              const all = hrefs(inside);
              count = inside.length;
              list = single(all);
              mixed = list.length < all.length;
              if (list.some((h) => shape.test(h))) break;
            }
            return { links: list, count: count, mixed: mixed };
          };
          for (const f of found) {
            if (items.length >= 8) break;
            if (f.title.length < 4 || flat.indexOf(f.title) < 0 || seen[f.title]) continue;
            const named = anchors.filter((a) => a.text.indexOf(f.title) >= 0).map((a) => a.el);
            const hold = holder(f.title);
            // 이미 지나간(화면 위로 올라간) 상품은 뺀다
            const mark = named.length ? named[0] : hold;
            if (mark && isShown(mark) && mark.getBoundingClientRect().bottom < 0) continue;
            const price = f.prices.find((n) => confirmed(n)) || null;
            const wrap = hold ? hold.closest("a[href]") : null;
            const near = hold ? around(hold, f.title) : { links: [], count: 0, mixed: false };
            const links = pick(hrefs(named).concat(wrap ? [hrefOf(wrap)] : [], f.urls, near.links));
            // 상품 주소가 둘이라 가리지 못한 것은 "링크가 없다"도 "주소가 없다"도 아니다 (앱은 이것을 no_link로 알린다)
            const why = near.mixed ? "mixed" : (named.length || wrap || near.count ? "no_href" : "no_anchor");
            add(f.title, price, f.mall && flat.indexOf(f.mall) >= 0 ? f.mall : "", links, why);
          }
        }

        // 2) 화면의 글에서: 가격 하나를 둘러싼 가장 큰 덩어리를 상품 한 칸으로 본다
        if (!items.length) {
          const live = tokens.filter((t) => !t.struck);
          const label = /^(배송비|무료배송$|리뷰|구매\s*[\d,]|찜|별점|평점|광고|쿠폰|적립|등록일|톡톡|정보 수정|최대\s*[\d,]+\s*원)/;
          for (const t of live) {
            if (items.length >= 8) break;
            let card = null;
            for (let e = t.el.parentElement, i = 0; e && e !== body && i < 7; e = e.parentElement, i++) {
              const inside = live.filter((u) => e.contains(u.el)).map((u) => u.value).filter(uniq);
              if (inside.length > 1) break;
              if (norm(e.innerText).length >= 12) card = e;
            }
            if (!card || card.getBoundingClientRect().bottom < 0) continue;
            const names = (card.innerText || "").split("\n").map(norm)
              .filter((l) => l.length >= 6 && l.length <= 120 && !/^[\d,.\s%~원개건]+$/.test(l) && !label.test(l));
            if (!names.length) continue;
            const name = names.reduce((a, b) => (b.length > a.length ? b : a));
            // 그 칸을 감싼 링크, 이름이 든 링크, 칸 안의 다른 링크 차례로
            const cardLinks = Array.prototype.slice.call(card.querySelectorAll("a[href]"), 0, 40);
            const named = cardLinks.filter((a) => norm(a.textContent).indexOf(name) >= 0);
            const wrap = card.closest("a[href]");
            add(name, t.value, "", pick(hrefs([wrap].concat(named, cardLinks))), wrap || cardLinks.length ? "no_href" : "no_anchor");
          }
        }
        return JSON.stringify({ items: items });
      }

      // 상품 화면
      const meta = (name) => {
        const el = document.querySelector('meta[property="' + name + '"], meta[name="' + name + '"]');
        return el ? norm(el.getAttribute("content")) : "";
      };
      const ld = [];
      document.querySelectorAll('script[type="application/ld+json"]').forEach((s) => {
        try {
          const push = (x) => {
            if (!x || typeof x !== "object") return;
            if (Array.isArray(x)) { x.forEach(push); return; }
            ld.push(x);
            if (x["@graph"]) push(x["@graph"]);
          };
          push(JSON.parse(s.textContent));
        } catch (e) {}
      });
      const isType = (x, t) => x["@type"] === t || (Array.isArray(x["@type"]) && x["@type"].indexOf(t) >= 0);
      const product = ld.find((x) => isType(x, "Product")) || null;
      const offers = product ? [].concat(product.offers || []).filter((o) => o && typeof o === "object") : [];

      // 페이지가 스크립트에 적어 둔 상품 정보 (있을 때만. 값은 아래에서 화면과 맞춰 본다)
      let item = null;
      for (const s of document.querySelectorAll("script:not([src])")) {
        const text = s.textContent || "";
        const at = text.indexOf("__PRELOADED_STATE__");
        if (at < 0 || text.length > 3000000) continue;
        const eq = text.indexOf("=", at);
        if (eq < 0) break;
        let json = text.slice(eq + 1).trim();
        if (json.endsWith(";")) json = json.slice(0, -1);
        try {
          const p = JSON.parse(json).product;
          if (p && typeof p === "object") {
            if (typeof p.name === "string") item = p;
            else for (const k in p) { if (p[k] && typeof p[k] === "object" && typeof p[k].name === "string") { item = p[k]; break; } }
          }
        } catch (e) {}
        break;
      }

      // 가격
      const cands = [];
      const cand = (v) => { const n = toInt(v); if (n !== null && cands.indexOf(n) < 0) cands.push(n); };
      if (item) {
        const b = item.benefitsView && typeof item.benefitsView === "object" ? item.benefitsView : {};
        cand(b.mobileDiscountedSalePrice); cand(b.discountedSalePrice); cand(item.discountedSalePrice); cand(item.salePrice);
      }
      offers.forEach((o) => cand(o.price));
      cand(meta("product:price:amount")); cand(meta("og:price:amount"));
      let price = cands.find((n) => confirmed(n)) || null;
      if (price === null) {
        const live = tokens.filter((t) => !t.struck);
        if (live.length) {
          const top = Math.max.apply(null, live.map((t) => t.size));
          const biggest = live.filter((t) => t.size === top).map((t) => t.value).filter(uniq);
          const others = live.some((t) => t.size < top);
          if (top > 0 && biggest.length === 1 && (others || live.length === 1)) price = biggest[0];
        }
      }
      let original = null;
      if (price !== null) {
        const struck = tokens.filter((t) => t.struck && t.value > price).map((t) => t.value).filter(uniq);
        const known = item ? toInt(item.salePrice) : null;
        if (known && struck.indexOf(known) >= 0) original = known;
        else if (struck.length === 1) original = struck[0];
      }
      const member = price !== null
        && lines.some((l) => l.length <= 60 && l.indexOf(fmt(price)) >= 0 && /(회원가|멤버십\s*전용가|멤버십가)/.test(l));

      // 이름
      const og = meta("og:title");
      let title = "";
      for (const c of [item ? item.name : "", product ? product.name : "", og]) {
        const t = norm(c);
        if (t.length >= 2 && flat.indexOf(t) >= 0) { title = t; break; }
      }
      if (!title) title = og;

      // 판매처: 페이지가 적어 둔 이름이 화면에도 보일 때만
      let seller = "";
      const sellers = [];
      if (item && item.channel && typeof item.channel.channelName === "string") sellers.push(item.channel.channelName);
      offers.forEach((o) => { if (o.seller && typeof o.seller.name === "string") sellers.push(o.seller.name); });
      if (og && title && og !== title && og.indexOf(title) === 0) sellers.push(og.slice(title.length).replace(/^[\s:|\-–·]+/, ""));
      for (const c of sellers) {
        const t = norm(c);
        if (t.length >= 1 && t.length <= 60 && flat.indexOf(t) >= 0) { seller = t; break; }
      }

      // 배송·도착·재고: 화면의 줄 그대로
      let shipping = "", arrival = "", stock = "";
      const soldOut = offers.some((o) => /OutOfStock|SoldOut/i.test(String(o.availability || ""))) || (item && item.stockQuantity === 0);
      const cap = Math.min(lines.length, 1500);
      for (let i = 0; i < cap; i++) {
        const l = lines[i];
        if (!shipping) {
          if (l.length <= 80 && /배송비\s*:?\s*(무료|[\d,]+\s*원)/.test(l)) shipping = l;
          else if (/^(무료\s*배송|배송비\s*무료)$/.test(l)) shipping = l;
          else if (/^(배송비|택배배송)$/.test(l) && i + 1 < cap && lines[i + 1].length <= 60 && /^(무료|[\d,]+\s*원)/.test(lines[i + 1])) {
            shipping = l + " " + lines[i + 1];
          }
        }
        if (!arrival && l.length <= 60 && /도착/.test(l) && /(오늘|내일|모레|\d+\s*\/\s*\d+|\d+월\s*\d+일|요일|보장|예정)/.test(l)) arrival = l;
        if (!stock) {
          if (soldOut && /^(품절|일시\s*품절|재고\s*없음|구매\s*불가)$/.test(l)) stock = l;
          else if (l.length <= 60 && /(남은\s*수량|재고)\s*:?\s*[\d,]+\s*개/.test(l)) stock = l;
          else if (l.length <= 60 && /현재 구매하실 수 없는 상품/.test(l)) stock = l;
        }
      }

      // 옵션: 화면에 나와 있는 고르기 칸만 (정렬 같은 칸은 뺀다)
      const options = [];
      const keep = (name, values) => {
        if (options.length >= 8 || !values.length || /정렬/.test(name) || values.every((v) => /순$/.test(v))) return;
        options.push({ name: (name || "옵션").slice(0, 40), values: values.filter(uniq).slice(0, 20) });
      };
      document.querySelectorAll("select").forEach((sel) => {
        if (!isShown(sel)) return;
        const values = [];
        let hint = "";
        for (const o of sel.options) {
          const t = norm(o.textContent);
          if (!t) continue;
          if (o.value === "") { if (!hint) hint = t; continue; }
          values.push(t.slice(0, 60));
        }
        const label = sel.id ? document.querySelector('label[for="' + CSS.escape(sel.id) + '"]') : null;
        keep(norm(sel.getAttribute("aria-label")) || (label ? norm(label.innerText) : "") || norm(sel.getAttribute("title")) || hint, values);
      });
      document.querySelectorAll('[role="listbox"]').forEach((box) => {
        if (box.tagName === "SELECT" || !isShown(box)) return;
        const values = [];
        box.querySelectorAll('[role="option"]').forEach((o) => {
          const t = norm(o.innerText);
          if (t && isShown(o)) values.push(t.slice(0, 60));
        });
        let name = norm(box.getAttribute("aria-label"));
        const by = box.getAttribute("aria-labelledby");
        if (!name && by) {
          const el = document.getElementById(by.split(/\s+/)[0]);
          if (el) name = norm(el.innerText);
        }
        keep(name, values);
      });

      const result = { title: title, shipping: shipping, seller: seller, arrival: arrival, stock: stock, options: options };
      if (price !== null) result.price = price;
      if (original !== null) result.original_price = original;
      if (member) result.member_price = true;
      return JSON.stringify(result);
    } catch (e) {
      return "{}";
    }
    """#
}

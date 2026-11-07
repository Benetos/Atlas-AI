const BOOKMARK_KEY = "atlas.web.bookmarks.v1";
const CHIPS = [
  "What is Ferrite Dust for?",
  "Circuit Board recipe",
  "Refining Carbon",
  "How do I cook food?",
];

const state = {
  manifest: null,
  route: parseRoute(),
};

const app = document.getElementById("app");
const nav = document.getElementById("nav");

window.addEventListener("hashchange", () => {
  state.route = parseRoute();
  render();
});

init();

async function init() {
  try {
    state.manifest = await api("/api/manifest");
  } catch (error) {
    state.manifest = null;
    state.bootError = error.message || String(error);
  }
  render();
}

function parseRoute() {
  const raw = (location.hash || "#/ask").replace(/^#/, "");
  const parts = raw.split("/").filter(Boolean);
  if (parts[0] === "item" && parts[1] && parts[2]) {
    return { name: "item", type: parts[1], id: decodeURIComponent(parts[2]) };
  }
  if (parts[0] === "recipe" && parts[1]) {
    return { name: "recipe", id: decodeURIComponent(parts[1]) };
  }
  if (parts[0] === "library") {
    return { name: "library", facet: parts[1] || "product" };
  }
  if (parts[0] === "saved") return { name: "saved" };
  if (parts[0] === "info") return { name: "info" };
  return { name: "ask", q: parts[0] === "ask" ? decodeURIComponent(parts.slice(1).join("/") || "") : "" };
}

function setNav() {
  for (const link of nav.querySelectorAll("a")) {
    const route = link.dataset.route;
    const active =
      (route === "ask" && (state.route.name === "ask" || state.route.name === "item" || state.route.name === "recipe")) ||
      route === state.route.name;
    link.classList.toggle("active", Boolean(active));
  }
}

async function render() {
  setNav();
  if (state.bootError) {
    app.innerHTML = `<section class="panel miss">${escapeHtml(state.bootError)}</section>`;
    return;
  }
  switch (state.route.name) {
    case "ask":
      await renderAsk();
      break;
    case "library":
      await renderLibrary();
      break;
    case "saved":
      renderSaved();
      break;
    case "info":
      renderInfo();
      break;
    case "item":
      await renderItem();
      break;
    case "recipe":
      await renderRecipe();
      break;
    default:
      app.innerHTML = `<section class="panel miss">not in this snapshot.</section>`;
  }
}

async function renderAsk() {
  const initial = state.route.q || "";
  app.innerHTML = `
    <section class="panel hero">
      <h1>Atlas</h1>
      <p>Ask the pinned local snapshot. No cloud model. Misses stay offline.</p>
      <form class="search-row" id="ask-form">
        <input id="ask-input" name="q" type="search" placeholder="What is Ferrite Dust for?" value="${escapeAttr(initial)}" autocomplete="off" />
        <button type="submit">Ask</button>
      </form>
      <div class="chips" id="chips"></div>
      <div id="ask-results"></div>
    </section>
  `;
  const chips = document.getElementById("chips");
  for (const chip of CHIPS) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "chip";
    button.textContent = chip;
    button.addEventListener("click", () => {
      navigateAsk(chip);
    });
    chips.appendChild(button);
  }
  document.getElementById("ask-form").addEventListener("submit", (event) => {
    event.preventDefault();
    const value = document.getElementById("ask-input").value.trim();
    if (value) navigateAsk(value);
  });
  if (initial) {
    await fillAskResults(initial);
  }
}

function navigateAsk(prompt) {
  const next = `#/ask/${encodeURIComponent(prompt)}`;
  if (location.hash === next) {
    fillAskResults(prompt);
    return;
  }
  location.hash = next;
}

async function fillAskResults(prompt) {
  const target = document.getElementById("ask-results");
  if (!target) return;
  target.innerHTML = `<p class="muted">Searching snapshot…</p>`;
  try {
    const data = await api(`/api/ask?q=${encodeURIComponent(prompt)}`);
    if (data.miss) {
      target.innerHTML = `<div class="miss">not in this snapshot.</div>`;
      return;
    }
    target.innerHTML = `
      <p class="summary">${escapeHtml(data.summary)}</p>
      ${data.entities.length ? `<h2 class="section-title">Items</h2><div class="card-grid" id="entity-cards"></div>` : ""}
      ${data.recipes.length ? `<h2 class="section-title">Recipes</h2><div class="card-grid" id="recipe-cards"></div>` : ""}
      ${data.content.length ? `<h2 class="section-title">Feature records</h2><div class="card-grid" id="content-cards"></div>` : ""}
    `;
    fillEntityCards("entity-cards", data.entities);
    fillRecipeCards("recipe-cards", data.recipes);
    fillContentCards("content-cards", data.content);
  } catch (error) {
    target.innerHTML = `<div class="miss">${escapeHtml(error.message || String(error))}</div>`;
  }
}

async function renderLibrary() {
  const facet = state.route.facet || "product";
  const facets = [
    ["product", "Products"],
    ["substance", "Substances"],
    ["technology", "Technology"],
    ["crafting", "Crafting"],
    ["refining", "Refining"],
    ["cooking", "Cooking"],
  ];
  app.innerHTML = `
    <section class="panel">
      <h1 class="section-title" style="margin-top:0;font-size:1.8rem">Library</h1>
      <p class="muted">Browse the pinned snapshot by type or recipe kind.</p>
      <div class="chips" id="facet-chips"></div>
      <div class="card-grid" id="library-list"><p class="muted">Loading…</p></div>
      <div class="toolbar">
        <button class="text-btn" type="button" id="load-more" hidden>Load more</button>
      </div>
    </section>
  `;
  const chips = document.getElementById("facet-chips");
  for (const [id, label] of facets) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `chip${id === facet ? " active" : ""}`;
    button.textContent = label;
    button.addEventListener("click", () => {
      location.hash = `#/library/${id}`;
    });
    chips.appendChild(button);
  }

  const list = document.getElementById("library-list");
  const loadMore = document.getElementById("load-more");
  let offset = 0;
  const pageSize = 40;
  let loading = false;

  async function loadPage(reset = false) {
    if (loading) return;
    loading = true;
    try {
      const isEntity = ["product", "substance", "technology"].includes(facet);
      const url = isEntity
        ? `/api/entities?type=${encodeURIComponent(facet)}&limit=${pageSize}&offset=${offset}`
        : `/api/recipes?kind=${encodeURIComponent(facet)}&limit=${pageSize}&offset=${offset}`;
      const data = await api(url);
      if (reset) list.innerHTML = "";
      if (!data.items.length && offset === 0) {
        list.innerHTML = `<p class="empty">not in this snapshot.</p>`;
        loadMore.hidden = true;
        return;
      }
      if (isEntity) {
        for (const entity of data.items) list.appendChild(entityCard(entity));
      } else {
        for (const recipe of data.items) list.appendChild(recipeCard(recipe));
      }
      offset += data.items.length;
      loadMore.hidden = data.items.length < pageSize;
    } catch (error) {
      list.innerHTML = `<div class="miss">${escapeHtml(error.message || String(error))}</div>`;
      loadMore.hidden = true;
    } finally {
      loading = false;
    }
  }

  loadMore.addEventListener("click", () => loadPage(false));
  await loadPage(true);
}

function renderSaved() {
  const bookmarks = loadBookmarks();
  app.innerHTML = `
    <section class="panel">
      <h1 class="section-title" style="margin-top:0;font-size:1.8rem">Saved</h1>
      <p class="muted">Bookmarks stay in this browser. No accounts.</p>
      <div class="card-grid" id="saved-list"></div>
    </section>
  `;
  const list = document.getElementById("saved-list");
  if (!bookmarks.length) {
    list.innerHTML = `<p class="empty">No bookmarks yet.</p>`;
    return;
  }
  for (const item of bookmarks) {
    if (item.kind === "entity") {
      list.appendChild(
        entityCard({
          entity_type: item.entity_type,
          game_id: item.game_id,
          title: item.title,
          display_name: item.title,
          subtitle: item.subtitle || item.entity_type,
        })
      );
    } else if (item.kind === "recipe") {
      list.appendChild(
        recipeCard({
          recipe_id: item.recipe_id,
          recipe_kind: item.recipe_kind,
          output_title: item.title,
          recipe_name: item.title,
        })
      );
    }
  }
}

function renderInfo() {
  const manifest = state.manifest || {};
  const counts = manifest.counts || {};
  app.innerHTML = `
    <section class="panel info-block">
      <h1 class="section-title" style="margin-top:0;font-size:1.8rem">Info</h1>
      <p>${escapeHtml(manifest.private_notice || "Private Atlas companion for local use.")}</p>
      <dl>
        <dt>Source commit</dt>
        <dd><code>${escapeHtml(manifest.source_commit_sha || "unknown")}</code></dd>
        <dt>Entities</dt>
        <dd>${escapeHtml(String(counts.entities ?? "—"))}</dd>
        <dt>Recipes</dt>
        <dd>${escapeHtml(String(counts.recipes ?? "—"))}</dd>
        <dt>Recipe ingredients</dt>
        <dd>${escapeHtml(String(counts.recipe_ingredients ?? "—"))}</dd>
        <dt>Feature records</dt>
        <dd>${escapeHtml(String(counts.content_records ?? "—"))}</dd>
        <dt>Generated</dt>
        <dd>${escapeHtml(manifest.generated_at || "—")}</dd>
        <dt>Source</dt>
        <dd><a href="${escapeAttr(manifest.source_repository || "https://github.com/ApexFatality93/NMS-Handbook")}" target="_blank" rel="noreferrer">ApexFatality93/NMS-Handbook</a></dd>
      </dl>
      <p class="muted">${escapeHtml(manifest.attribution || "")}</p>
      <p class="muted">Icons are type-colored placeholders. Extracted images are not bundled. Licensing posture remains internal.</p>
    </section>
  `;
}

async function renderItem() {
  const { type, id } = state.route;
  app.innerHTML = `<section class="panel"><p class="muted">Loading item…</p></section>`;
  try {
    const data = await api(`/api/entities/${encodeURIComponent(type)}/${encodeURIComponent(id)}`);
    const entity = data.entity;
    const bookmarked = isBookmarked({ kind: "entity", entity_type: type, game_id: id });
    app.innerHTML = `
      <section class="panel">
        <div class="detail-header">
          ${iconHtml(entity.entity_type)}
          <div>
            <h1>${escapeHtml(entity.title)}</h1>
            <p class="identity-line">
              ${escapeHtml(entity.display_name || "—")}
              · ${escapeHtml(entity.name || "—")}
              · <code>${escapeHtml(entity.game_id)}</code>
            </p>
          </div>
        </div>
        <div class="toolbar">
          <button class="primary-btn" type="button" id="bookmark-btn">${bookmarked ? "Remove bookmark" : "Bookmark"}</button>
          <a class="text-btn" href="#/ask">Back to Ask</a>
        </div>
        <div class="facts">
          ${fact("Type", entity.entity_type)}
          ${fact("Category", entity.category)}
          ${fact("Subcategory", entity.subcategory)}
          ${fact("Rarity", entity.rarity)}
          ${fact("Legality", entity.legality)}
          ${fact("Base value", entity.base_value)}
          ${fact("Subtitle", entity.subtitle)}
        </div>
        ${entity.description ? `<p class="description">${escapeHtml(entity.description)}</p>` : ""}
        <h2 class="section-title">Recipes that produce this</h2>
        <div class="card-grid" id="producing"></div>
        <h2 class="section-title">Recipes that consume this</h2>
        <div class="card-grid" id="using"></div>
      </section>
    `;
    document.getElementById("bookmark-btn").addEventListener("click", () => {
      toggleBookmark({
        kind: "entity",
        entity_type: entity.entity_type,
        game_id: entity.game_id,
        title: entity.title,
        subtitle: entity.subtitle || entity.entity_type,
      });
      renderItem();
    });
    fillRecipeCards("producing", data.producing);
    fillRecipeCards("using", data.using);
    if (!data.producing.length) {
      document.getElementById("producing").innerHTML = `<p class="empty">No producing recipes in this snapshot.</p>`;
    }
    if (!data.using.length) {
      document.getElementById("using").innerHTML = `<p class="empty">No consuming recipes in this snapshot.</p>`;
    }
  } catch (error) {
    app.innerHTML = `<section class="panel miss">${escapeHtml(error.message || "not in this snapshot.")}</section>`;
  }
}

async function renderRecipe() {
  const { id } = state.route;
  app.innerHTML = `<section class="panel"><p class="muted">Loading recipe…</p></section>`;
  try {
    const data = await api(`/api/recipes/${encodeURIComponent(id)}`);
    const recipe = data.recipe;
    const title = recipe.recipe_name || recipe.output_title || recipe.recipe_id;
    const bookmarked = isBookmarked({ kind: "recipe", recipe_id: recipe.recipe_id });
    app.innerHTML = `
      <section class="panel">
        <div class="detail-header">
          ${iconHtml(recipe.recipe_kind)}
          <div>
            <h1>${escapeHtml(title)}</h1>
            <p class="identity-line">${escapeHtml(recipe.recipe_kind)} · <code>${escapeHtml(recipe.recipe_id)}</code></p>
          </div>
        </div>
        <div class="toolbar">
          <button class="primary-btn" type="button" id="bookmark-btn">${bookmarked ? "Remove bookmark" : "Bookmark"}</button>
          <a class="text-btn" href="#/item/${encodeURIComponent(recipe.output_entity_type)}/${encodeURIComponent(recipe.output_game_id)}">Open output item</a>
        </div>
        <div class="facts">
          ${fact("Kind", recipe.recipe_kind)}
          ${fact("Output amount", recipe.output_amount)}
          ${fact("Time (seconds)", recipe.time_seconds)}
          ${fact("Recipe type", recipe.recipe_type)}
          ${fact("Output", recipe.output_title || recipe.output_game_id)}
        </div>
        <h2 class="section-title">Ingredients</h2>
        <ul class="ingredient-list" id="ingredients"></ul>
      </section>
    `;
    document.getElementById("bookmark-btn").addEventListener("click", () => {
      toggleBookmark({
        kind: "recipe",
        recipe_id: recipe.recipe_id,
        recipe_kind: recipe.recipe_kind,
        title,
      });
      renderRecipe();
    });
    const list = document.getElementById("ingredients");
    if (!recipe.ingredients.length) {
      list.innerHTML = `<li class="empty">No ingredients in this snapshot.</li>`;
    } else {
      for (const ingredient of recipe.ingredients) {
        const li = document.createElement("li");
        li.innerHTML = `
          <a href="#/item/${encodeURIComponent(ingredient.entity_type)}/${encodeURIComponent(ingredient.game_id)}">
            ${escapeHtml(ingredient.title || ingredient.game_id)}
          </a>
          <span class="muted">${escapeHtml(ingredient.amount == null ? "—" : String(ingredient.amount))}</span>
        `;
        list.appendChild(li);
      }
    }
  } catch (error) {
    app.innerHTML = `<section class="panel miss">${escapeHtml(error.message || "not in this snapshot.")}</section>`;
  }
}

function fillEntityCards(id, items) {
  const root = document.getElementById(id);
  if (!root) return;
  root.innerHTML = "";
  for (const entity of items) root.appendChild(entityCard(entity));
}

function fillRecipeCards(id, items) {
  const root = document.getElementById(id);
  if (!root) return;
  root.innerHTML = "";
  for (const recipe of items) root.appendChild(recipeCard(recipe));
}

function fillContentCards(id, items) {
  const root = document.getElementById(id);
  if (!root) return;
  root.innerHTML = "";
  for (const record of items) {
    const card = document.createElement("div");
    card.className = "card";
    card.innerHTML = `
      ${iconHtml("product")}
      <div class="card-copy">
        <h3>${escapeHtml(record.title || record.external_id)}</h3>
        <p>${escapeHtml(record.dataset)}</p>
      </div>
      <div class="meta">feature</div>
    `;
    root.appendChild(card);
  }
}

function entityCard(entity) {
  const link = document.createElement("a");
  link.className = "card";
  link.href = `#/item/${encodeURIComponent(entity.entity_type)}/${encodeURIComponent(entity.game_id)}`;
  link.innerHTML = `
    ${iconHtml(entity.entity_type)}
    <div class="card-copy">
      <h3>${escapeHtml(entity.title || entity.display_name || entity.name || entity.game_id)}</h3>
      <p>${escapeHtml(entity.subtitle || entity.category || entity.entity_type)}</p>
    </div>
    <div class="meta">${escapeHtml(entity.entity_type)}</div>
  `;
  return link;
}

function recipeCard(recipe) {
  const link = document.createElement("a");
  link.className = "card";
  link.href = `#/recipe/${encodeURIComponent(recipe.recipe_id)}`;
  const title = recipe.recipe_name || recipe.output_title || recipe.recipe_id;
  link.innerHTML = `
    ${iconHtml(recipe.recipe_kind)}
    <div class="card-copy">
      <h3>${escapeHtml(title)}</h3>
      <p>${escapeHtml(recipe.recipe_kind)}${recipe.output_amount ? ` · ×${escapeHtml(String(recipe.output_amount))}` : ""}</p>
    </div>
    <div class="meta">${escapeHtml(recipe.recipe_kind)}</div>
  `;
  return link;
}

function iconHtml(kind) {
  const letter = (kind || "?").slice(0, 1).toUpperCase();
  const klass = ["product", "substance", "technology", "crafting", "refining", "cooking"].includes(kind)
    ? kind
    : "product";
  return `<div class="icon ${klass}" aria-hidden="true">${letter}</div>`;
}

function fact(label, value) {
  if (value == null || value === "") return "";
  return `<div class="fact"><span>${escapeHtml(label)}</span><strong>${escapeHtml(String(value))}</strong></div>`;
}

function loadBookmarks() {
  try {
    const raw = localStorage.getItem(BOOKMARK_KEY);
    const parsed = raw ? JSON.parse(raw) : [];
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function saveBookmarks(items) {
  localStorage.setItem(BOOKMARK_KEY, JSON.stringify(items));
}

function bookmarkKey(item) {
  if (item.kind === "entity") return `entity:${item.entity_type}:${item.game_id}`;
  return `recipe:${item.recipe_id}`;
}

function isBookmarked(item) {
  const key = bookmarkKey(item);
  return loadBookmarks().some((entry) => bookmarkKey(entry) === key);
}

function toggleBookmark(item) {
  const key = bookmarkKey(item);
  const current = loadBookmarks();
  if (current.some((entry) => bookmarkKey(entry) === key)) {
    saveBookmarks(current.filter((entry) => bookmarkKey(entry) !== key));
  } else {
    saveBookmarks([item, ...current]);
  }
}

async function api(path) {
  const response = await fetch(path, { headers: { Accept: "application/json" } });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(data.error || "not in this snapshot.");
  }
  return data;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function escapeAttr(value) {
  return escapeHtml(value).replaceAll("'", "&#39;");
}

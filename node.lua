gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

-- Polices DejaVu (licence libre, voir LICENCE-polices.txt)
local sans   = resource.load_font "sans.ttf"
local gras   = resource.load_font "sans-gras.ttf"
local serif  = resource.load_font "serif-italique.ttf"

-- Couleurs
local CREME     = {0.945, 0.910, 0.816}
local CREME_BORD = {0.880, 0.835, 0.715}
local CREME_CPT = {0.925, 0.886, 0.776}   -- fond des compteurs
local NOIR      = {0.114, 0.102, 0.086}
local ROUGE     = {0.847, 0.196, 0.118}
local OR        = {0.735, 0.560, 0.255}
local OR_FONCE  = {0.420, 0.300, 0.110}
local OR_CLAIR  = {0.930, 0.800, 0.470}

local function texture(c, a)
  return resource.create_colored_texture(c[1], c[2], c[3], a or 1)
end

local tex_blanc = texture{1, 1, 1}
local tex_noir  = texture(NOIR)
local tex_rouge = texture(ROUGE)

-- Reglages (tableau de bord info-beamer)
local trotteuse = true
local balayage  = true
local marque    = "GAËTAN CHRISTOPHE"
local nom_lune  = "Maëlle"
local texte_lune = "cadran lune"

util.json_watch("config.json", function(config)
  if config.trotteuse ~= nil then trotteuse = config.trotteuse end
  balayage   = (config.mouvement or "balayage") == "balayage"
  marque     = config.marque or marque
  nom_lune   = config.nom_lune or nom_lune
  texte_lune = config.texte_lune or texte_lune
end)

------------------------------------------------------------------------
-- Shaders
------------------------------------------------------------------------

-- Disque ou anneau lisse, avec degrade radial de c1 (centre) a c2 (bord)
-- a partir de la fraction "debut" du rayon. "trou" = rayon interieur.
local shader_disque = resource.create_shader[[
  #ifdef GL_ES
  precision mediump float;
  #endif
  uniform sampler2D Texture;
  varying vec2 TexCoord;
  uniform float r1, g1, b1, r2, g2, b2;
  uniform float debut, trou, px, alpha;
  void main() {
    float d = length((TexCoord - vec2(0.5)) * 2.0);
    float a = clamp((1.0 - d) / px + 0.5, 0.0, 1.0);
    if (trou > 0.0) a *= clamp((d - trou) / px + 0.5, 0.0, 1.0);
    vec3 c = mix(vec3(r1, g1, b1), vec3(r2, g2, b2), smoothstep(debut, 1.0, d));
    gl_FragColor = texture2D(Texture, TexCoord) * vec4(c, a * alpha);
  }
]]

-- Lunette en acier poli : reflets selon l'angle (lumiere en haut a gauche)
local shader_acier = resource.create_shader[[
  #ifdef GL_ES
  precision mediump float;
  #endif
  uniform sampler2D Texture;
  varying vec2 TexCoord;
  uniform float trou, px;
  void main() {
    vec2 p = (TexCoord - vec2(0.5)) * 2.0;
    float d = length(p);
    float a = clamp((1.0 - d) / px + 0.5, 0.0, 1.0) * clamp((d - trou) / px + 0.5, 0.0, 1.0);
    float ang = atan(p.y, p.x);
    float reflet = pow(0.5 + 0.5 * cos(ang + 2.36), 3.0);       // haut gauche
    float contre = pow(0.5 + 0.5 * cos(ang - 0.79), 6.0);       // bas droite
    float t = (d - trou) / (1.0 - trou);                        // 0 dedans, 1 dehors
    float bombe = 1.0 - pow(abs(t * 2.0 - 1.0), 2.0);           // profil arrondi
    float g = 0.50 + 0.28 * bombe + 0.22 * reflet + 0.10 * contre;
    g -= 0.18 * smoothstep(0.85, 1.0, t);                       // arete exterieure
    vec3 c = vec3(g * 0.97, g * 0.98, g);
    gl_FragColor = texture2D(Texture, TexCoord) * vec4(c, a);
  }
]]

-- Aiguille en forme de lance : fine a la base, s'elargit puis s'effile en
-- pointe. Coordonnees en pixels le long de l'aiguille (y vers la pointe).
-- Optionnel : contrepoids rond sur la queue (trotteuse).
local shader_aiguille = resource.create_shader[[
  #ifdef GL_ES
  precision mediump float;
  #endif
  uniform sampler2D Texture;
  varying vec2 TexCoord;
  uniform float x0, x1, y0, y1;          // etendue du quad
  uniform float L, Q, W, P, qw, tw;      // longueur, queue, demi-largeurs
  uniform float boule, yb, moyeu;        // contrepoids et moyeu (rayons)
  uniform float r, g, b, alpha;
  void main() {
    vec2 p = vec2(mix(x0, x1, TexCoord.x), mix(y1, y0, TexCoord.y));
    float hw;
    if (p.y < 0.0) hw = qw;
    else if (p.y < P * L) hw = mix(qw, W, p.y / (P * L));
    else hw = mix(W, tw, (p.y - P * L) / (L - P * L));
    float d = min(hw - abs(p.x), min(p.y + Q, L - p.y));
    d = max(d, moyeu - length(p));
    if (boule > 0.0) d = max(d, boule - length(p - vec2(0.0, -yb)));
    float a = clamp(d + 0.5, 0.0, 1.0);
    gl_FragColor = texture2D(Texture, TexCoord) * vec4(r, g, b, a * alpha);
  }
]]

-- Fenetre de phase de lune : ciel etoile et deux lunes sur un disque qui
-- tourne d'un demi-tour par lunaison, vus a travers l'ouverture a deux bosses.
-- Unites : 1 = 1/86 du rayon de l'ouverture ; y vers le haut.
local shader_lune = resource.create_shader[[
  #ifdef GL_ES
  precision mediump float;
  #endif
  uniform sampler2D Texture;
  varying vec2 TexCoord;
  uniform float k;        // pixels par unite
  uniform float angle;    // rotation du disque (radians, sens horaire)

  float etoile(vec2 p, vec2 c, float r) {
    p -= c;
    const vec2 k1 = vec2(0.809016994, -0.587785252);
    const vec2 k2 = vec2(-0.809016994, -0.587785252);
    p.x = abs(p.x);
    p -= 2.0 * max(dot(k1, p), 0.0) * k1;
    p -= 2.0 * max(dot(k2, p), 0.0) * k2;
    p.x = abs(p.x);
    p.y -= r;
    vec2 ba = 0.42 * vec2(-k1.y, k1.x) - vec2(0.0, 1.0);
    float h = clamp(dot(p, ba) / dot(ba, ba), 0.0, r);
    return length(p - ba * h) * sign(p.y * ba.x - p.x * ba.y);
  }

  // Lune doree en relief, avec quelques crateres
  vec4 lune(vec2 p, vec2 c) {
    vec2 q = (p - c) / 34.0;
    float d = length(q);
    float a = clamp((1.0 - d) * 34.0 * k + 0.5, 0.0, 1.0);
    vec3 col = mix(vec3(0.96, 0.78, 0.36), vec3(0.74, 0.54, 0.20), smoothstep(0.2, 1.0, length(q - vec2(-0.3, 0.3))));
    float cr = smoothstep(0.24, 0.18, length(q - vec2(-0.25, 0.20)))
             + smoothstep(0.16, 0.11, length(q - vec2(0.32, -0.28)))
             + smoothstep(0.12, 0.08, length(q - vec2(0.18, 0.42)))
             + smoothstep(0.10, 0.06, length(q - vec2(-0.40, -0.35)));
    col = mix(col, vec3(0.70, 0.52, 0.19), clamp(cr, 0.0, 1.0) * 0.6);
    return vec4(col, a);
  }

  void main() {
    vec2 q = (TexCoord - vec2(0.5)) * 2.0 * 92.0;
    q.y = -q.y;
    // Ouverture : demi-disque de rayon 86 moins deux bosses de rayon 43
    float d = min(min(86.0 - length(q), q.y),
                  min(length(q - vec2(43.0, 0.0)) - 43.0, length(q + vec2(43.0, 0.0)) - 43.0));
    float dedans = clamp(d * k + 0.5, 0.0, 1.0);
    float bord = clamp((1.1 - abs(d)) * k + 0.5, 0.0, 1.0);

    float c = cos(angle), s = sin(angle);
    vec2 p = vec2(q.x * c - q.y * s, q.x * s + q.y * c);

    vec3 ciel = mix(vec3(0.16, 0.30, 0.66), vec3(0.09, 0.18, 0.46), clamp(length(q) / 86.0, 0.0, 1.0));
    vec2 m = p.y > 0.0 ? p : -p;     // le disque est symetrique
    float e = min(min(min(etoile(m, vec2(-58.0, 22.0), 6.0), etoile(m, vec2(-38.0, -8.0), 4.5)),
                      min(etoile(m, vec2(-72.0, -20.0), 4.0), etoile(m, vec2(-40.0, 45.0), 4.0))),
                  min(min(etoile(m, vec2(52.0, 40.0), 5.0), etoile(m, vec2(64.0, 10.0), 4.0)),
                      min(etoile(m, vec2(30.0, 8.0), 5.0), etoile(m, vec2(76.0, -30.0), 3.5))));
    vec3 col = mix(ciel, vec3(0.97, 0.82, 0.36), clamp(-e * k + 0.5, 0.0, 1.0));
    vec4 l = lune(m, vec2(0.0, 62.0));
    col = mix(col, l.rgb, l.a);

    col = mix(col, vec3(0.114, 0.102, 0.086), bord);
    gl_FragColor = texture2D(Texture, TexCoord) * vec4(col, max(dedans, bord));
  }
]]

------------------------------------------------------------------------
-- Outils de dessin
------------------------------------------------------------------------

local function disque(x, y, rayon, c1, c2, debut, trou, alpha)
  c2 = c2 or c1
  shader_disque:use{
    r1 = c1[1], g1 = c1[2], b1 = c1[3], r2 = c2[1], g2 = c2[2], b2 = c2[3],
    debut = debut or 0, trou = trou or 0, px = 1.2 / rayon, alpha = alpha or 1,
  }
  tex_blanc:draw(x - rayon, y - rayon, x + rayon, y + rayon)
  shader_disque:deactivate()
end

-- Cercle trace (anneau d'epaisseur "ep" pixels)
local function cercle(x, y, rayon, ep, c)
  disque(x, y, rayon + ep / 2, c, c, 0, (rayon - ep / 2) / (rayon + ep / 2))
end

-- Rectangle tourne autour de (x, y) (angle en degres, 0 = vers le haut)
local function trait(x, y, angle, debut, fin, largeur, tex)
  gl.pushMatrix()
  gl.translate(x, y)
  gl.rotate(angle, 0, 0, 1)
  tex:draw(-largeur / 2, -fin, largeur / 2, -debut)
  gl.popMatrix()
end

local function polar(x, y, r, angle)
  local a = math.rad(angle)
  return x + math.sin(a) * r, y - math.cos(a) * r
end

local function centre(f, texte, x, y, taille, c, a)
  local w = f:width(texte, taille)
  f:write(x - w / 2, y - taille / 2, texte, taille, c[1], c[2], c[3], a or 1)
end

-- Texte tourne autour de son centre (haut du texte vers l'exterieur)
local function centre_tourne(f, texte, x, y, taille, angle, c)
  gl.pushMatrix()
  gl.translate(x, y)
  gl.rotate(angle, 0, 0, 1)
  local w = f:width(texte, taille)
  f:write(-w / 2, -taille / 2, texte, taille, c[1], c[2], c[3], 1)
  gl.popMatrix()
end

-- Chiffre dore en relief : contour brun, puis or, puis reflet en haut
local function chiffre_dore(texte, x, y, taille)
  local ep = taille * 0.035
  for i = 0, 7 do
    local a = i * math.pi / 4
    centre(gras, texte, x + math.cos(a) * ep, y + math.sin(a) * ep, taille, OR_FONCE)
  end
  centre(gras, texte, x + ep * 0.6, y + ep * 0.8, taille, OR_FONCE)
  centre(gras, texte, x, y, taille, OR)
  centre(gras, texte, x - ep * 0.35, y - ep * 0.45, taille, OR_CLAIR, 0.35)
end

-- Texte espace (lettres ecartees), centre
local function espace(f, texte, x, y, taille, ecart, c)
  local lettres = {}
  for ch in texte:gmatch("[%z\1-\127\194-\244][\128-\191]*") do lettres[#lettres + 1] = ch end
  local total = 0
  for _, ch in ipairs(lettres) do total = total + f:width(ch, taille) end
  total = total + ecart * (#lettres - 1)
  local xx = x - total / 2
  for _, ch in ipairs(lettres) do
    f:write(xx, y - taille / 2, ch, taille, c[1], c[2], c[3], 1)
    xx = xx + f:width(ch, taille) + ecart
  end
end

local function aiguille(x, y, angle, h, c, alpha)
  local larg = math.max(h.W, h.qw, h.boule or 0, h.moyeu or 0) + 2
  local bas  = h.Q + (h.boule or 0) + 2
  gl.pushMatrix()
  gl.translate(x, y)
  gl.rotate(angle, 0, 0, 1)
  shader_aiguille:use{
    x0 = -larg, x1 = larg, y0 = -bas, y1 = h.L + 1,
    L = h.L, Q = h.Q, W = h.W, P = h.P, qw = h.qw, tw = h.tw,
    boule = h.boule or 0, yb = h.yb or 0, moyeu = h.moyeu or 0,
    r = c[1], g = c[2], b = c[3], alpha = alpha or 1,
  }
  tex_blanc:draw(-larg, -(h.L + 1), larg, bas)
  shader_aiguille:deactivate()
  gl.popMatrix()
end

-- Aiguille avec son ombre portee sur le cadran
local function aiguille_ombre(x, y, angle, h, c, k)
  aiguille(x + 4 * k, y + 6 * k, angle, h, {0, 0, 0}, 0.22)
  aiguille(x, y, angle, h, c)
end

local function pignon(x, y, rayon)
  disque(x, y, rayon, OR_FONCE)
  disque(x, y, rayon * 0.88, OR_CLAIR, OR, 0.1)
  disque(x - rayon * 0.12, y - rayon * 0.12, rayon * 0.35, {1.0, 0.93, 0.70}, OR_CLAIR, 0.3)
end

------------------------------------------------------------------------
-- Heure de Paris (heure d'ete europeenne automatique)
------------------------------------------------------------------------

local function jour_semaine(y, m, d)   -- 0 = dimanche
  local t = {0,3,2,5,0,3,5,2,6,4,2,4}
  if m < 3 then y = y - 1 end
  return (y + math.floor(y/4) - math.floor(y/100) + math.floor(y/400) + t[m] + d) % 7
end

local function decalage(utc)
  local debut = 3 * 10000 + (31 - jour_semaine(utc.year, 3, 31)) * 100 + 1
  local fin   = 10 * 10000 + (31 - jour_semaine(utc.year, 10, 31)) * 100 + 1
  local now   = utc.month * 10000 + utc.day * 100 + utc.hour
  if now >= debut and now < fin then return 7200 end
  return 3600
end

-- Fraction de seconde : os.time() n'avance que d'une seconde a la fois
local seconde_vue, debut_seconde = nil, 0
local function fraction(t)
  if t ~= seconde_vue then seconde_vue, debut_seconde = t, sys.now() end
  return math.min(sys.now() - debut_seconde, 0.999)
end

-- Age de la lune en jours (nouvelle lune de reference : 6 janvier 2000, 18h14 UTC)
local LUNAISON = 29.530588
local function age_lune(t)
  return ((t - 947182440) / 86400) % LUNAISON
end

------------------------------------------------------------------------
-- Montre (unites de la maquette : rayon du cadran 455, ecran de 1080 de haut)
------------------------------------------------------------------------

local JOURS = {"DIM", "LUN", "MAR", "MER", "JEU", "VEN", "SAM"}

local acier       = texture{0.74, 0.76, 0.78}
local acier_fonce = texture{0.52, 0.54, 0.57}
local acier_clair = texture{0.88, 0.89, 0.91}

local function boitier(cx, cy, k)

  -- Couronne a 3 h (stries paralleles a son axe) et poussoir a 4 h
  trait(cx, cy, 90, 470 * k, 492 * k, 46 * k, acier_fonce)
  trait(cx, cy, 90, 488 * k, 548 * k, 96 * k, acier)
  for i = -6, 6 do
    gl.pushMatrix()
    gl.translate(cx, cy)
    gl.rotate(90, 0, 0, 1)
    local x = i * 7 * k
    acier_fonce:draw(x - 1.6 * k, -548 * k, x + 1.6 * k, -490 * k)
    gl.popMatrix()
  end
  trait(cx, cy, 90, 488 * k, 548 * k, 10 * k, acier_clair)
  trait(cx, cy, 122, 470 * k, 528 * k, 50 * k, acier)
  trait(cx, cy, 122, 512 * k, 538 * k, 38 * k, acier_fonce)
  trait(cx, cy, 122, 480 * k, 538 * k, 8 * k, acier_clair)

  -- Carrure et lunette polie
  shader_acier:use{trou = 470 / 505, px = 1.2 / (505 * k)}
  tex_blanc:draw(cx - 505 * k, cy - 505 * k, cx + 505 * k, cy + 505 * k)
  shader_acier:deactivate()

  -- Rehaut (ombre de la glace sur le bord du cadran)
  disque(cx, cy, 471 * k, {0.80, 0.74, 0.60}, {0.55, 0.50, 0.40}, 0.93)
end

local function cadran(cx, cy, k)
  disque(cx, cy, 455 * k, CREME, CREME_BORD, 0.55)

  -- Piste des minutes : deux cercles, chiffres de 5 en 5
  cercle(cx, cy, 446 * k, 2 * k, NOIR)
  cercle(cx, cy, 410 * k, 2 * k, NOIR)
  for i = 0, 11 do
    local x, y = polar(cx, cy, 428 * k, i * 30)
    centre(sans, tostring(i == 0 and 60 or i * 5), x, y, 30 * k, NOIR)
  end

  -- Chemin de fer interieur
  cercle(cx, cy, 392 * k, 1.6 * k, NOIR)
  cercle(cx, cy, 380 * k, 1.6 * k, NOIR)
  for i = 0, 59 do
    if i % 5 == 0 then
      trait(cx, cy, i * 6, 376 * k, 397 * k, 6 * k, tex_noir)
    else
      trait(cx, cy, i * 6, 380 * k, 392 * k, 2 * k, tex_noir)
    end
  end

  -- Chiffres dores (3, 6 et 9 laissent la place aux compteurs)
  for _, h in ipairs{12, 1, 2, 4, 5, 7, 8, 10, 11} do
    local x, y = polar(cx, cy, 318 * k, h * 30)
    chiffre_dore(tostring(h), x, y, 88 * k)
  end

  -- Marque sous le 12
  espace(sans, marque, cx, cy - 175 * k, 30 * k, 5 * k, NOIR)
end

local function compteur(x, y, k)
  disque(x, y, 113 * k, NOIR)
  disque(x, y, 111 * k, CREME_CPT, CREME, 0.0)
  cercle(x, y, 102 * k, 1 * k, {0.45, 0.42, 0.36})
end

-- Compteur des jours (a 9 h)
local function compteur_jours(x, y, k, wday)
  compteur(x, y, k)
  for i = 1, 7 do
    local a = (i - 1) * 360 / 7
    local tx, ty = polar(x, y, 80 * k, a)
    centre_tourne(sans, JOURS[i], tx, ty, 25 * k, a, i == 1 and ROUGE or NOIR)
    trait(x, y, a + 180 / 7, 66 * k, 104 * k, 2 * k, tex_noir)
  end
  aiguille_ombre(x, y, (wday - 1) * 360 / 7,
    {L = 90 * k, Q = 22 * k, W = 3.6 * k, P = 0.22, qw = 2.4 * k, tw = 0.5 * k}, NOIR, k * 0.6)
  pignon(x, y, 12 * k)
end

-- Compteur du quantieme (a 3 h)
local function compteur_dates(x, y, k, jour)
  compteur(x, y, k)
  for d = 1, 31 do
    local a = (d - 1) * 360 / 31
    local c = d == 31 and ROUGE or NOIR
    trait(x, y, a, (d % 2 == 1 and 93 or 97) * k, 104 * k, 2 * k, d == 31 and tex_rouge or tex_noir)
    if d % 2 == 1 then
      local tx, ty = polar(x, y, 77 * k, a)
      centre_tourne(sans, tostring(d), tx, ty, 21 * k, a, c)
    end
  end
  aiguille_ombre(x, y, (jour - 1) * 360 / 31,
    {L = 90 * k, Q = 22 * k, W = 3.6 * k, P = 0.22, qw = 2.4 * k, tw = 0.5 * k}, NOIR, k * 0.6)
  pignon(x, y, 12 * k)
end

-- Compteur de phase de lune (a 6 h)
local function compteur_lune(x, y, k, t)
  compteur(x, y, k)
  local angle = (age_lune(t) / LUNAISON) * math.pi - math.pi / 2
  local S = 92 * k
  shader_lune:use{k = k, angle = angle}
  tex_blanc:draw(x - S, y - S, x + S, y + S)
  shader_lune:deactivate()
  centre(serif, nom_lune, x, y + 34 * k, 30 * k, NOIR)
  centre(sans, texte_lune, x, y + 72 * k, 23 * k, NOIR)
end

local AIG_HEURE   = {L = 272, Q = 52, W = 9.5, P = 0.30, qw = 4.0, tw = 0.8, moyeu = 16}
local AIG_MINUTE  = {L = 405, Q = 62, W = 7.5, P = 0.26, qw = 3.4, tw = 0.6, moyeu = 14}
local AIG_SECONDE = {L = 430, Q = 98, W = 1.6, P = 0.05, qw = 2.4, tw = 0.9, boule = 11, yb = 74, moyeu = 9}

local function echelle(h, k)
  local r = {}
  for n, v in pairs(h) do r[n] = (n == "P") and v or v * k end
  return r
end

function node.render()
  gl.clear(0, 0, 0, 1)

  local t   = os.time()
  local fr  = fraction(t)
  local utc = os.date("!*t", t)
  local d   = os.date("!*t", t + decalage(utc))

  local k  = HEIGHT / 1080
  local cx, cy = WIDTH / 2, HEIGHT / 2

  boitier(cx, cy, k)
  cadran(cx, cy, k)
  compteur_jours(cx - 205 * k, cy, k, d.wday)
  compteur_dates(cx + 205 * k, cy, k, d.day)
  compteur_lune(cx, cy + 215 * k, k, t)

  local sec = d.sec + (balayage and math.floor(fr * 8) / 8 or 0)
  local m = d.min + sec / 60
  local h = (d.hour % 12) + m / 60
  aiguille_ombre(cx, cy, h * 30, echelle(AIG_HEURE, k), NOIR, k)
  aiguille_ombre(cx, cy, m * 6, echelle(AIG_MINUTE, k), NOIR, k)
  if trotteuse then
    aiguille_ombre(cx, cy, sec * 6, echelle(AIG_SECONDE, k), NOIR, k)
  end
  pignon(cx, cy, 13 * k)
end

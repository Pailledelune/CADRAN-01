gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

-- Image du cadran sans aiguilles (fond et fenetre de lune transparents)
-- et disque de lune qui tourne derriere la fenetre.
local fond = resource.load_image{file = "Cadran-01.png", mipmap = true}
local lune = resource.load_image{file = "lune.png", mipmap = true}

local tex_blanc = resource.create_colored_texture(1, 1, 1, 1)

local NOIR = {0.09, 0.08, 0.07}

-- Reglages (tableau de bord info-beamer)
local trotteuse = true
local balayage  = true

util.json_watch("config.json", function(config)
  if config.trotteuse ~= nil then trotteuse = config.trotteuse end
  balayage = (config.mouvement or "balayage") == "balayage"
end)

------------------------------------------------------------------------
-- Mesures prises sur Cadran-01.png (1000 x 1000 pixels)
------------------------------------------------------------------------

local IMAGE      = 1000
local TAILLE     = 1.10                  -- image = 110 % de la hauteur d'ecran
local BOITIER    = {500, 504}            -- centre du boitier (centre a l'ecran)
local AXE        = {500, 497}            -- pivot des aiguilles
local AXE_JOURS  = {339.5, 499}
local AXE_DATES  = {660, 499}
local AXE_LUNE   = {500, 662}            -- centre de l'arc de la fenetre de lune
local RAYON_LUNE = 136                   -- rayon du disque lune.png a l'ecran

------------------------------------------------------------------------
-- Aiguille en forme de lance : fine a la base, s'elargit puis s'effile en
-- pointe. Coordonnees en pixels le long de l'aiguille (y vers la pointe).
-- Optionnel : contrepoids rond sur la queue (trotteuse).
-- "flou" adoucit le bord (ombre), "facette" eclaire une moitie (arete).
------------------------------------------------------------------------

local shader_aiguille = resource.create_shader[[
  #ifdef GL_ES
  precision mediump float;
  #endif
  uniform sampler2D Texture;
  varying vec2 TexCoord;
  uniform float x0, x1, y0, y1;          // etendue du quad
  uniform float L, Q, W, P, qw, tw;      // longueur, queue, demi-largeurs
  uniform float boule, yb, moyeu;        // contrepoids et moyeu (rayons)
  uniform float r, g, b, alpha, flou, facette;
  void main() {
    vec2 p = vec2(mix(x0, x1, TexCoord.x), mix(y1, y0, TexCoord.y));
    float hw;
    if (p.y < 0.0) hw = qw;
    else if (p.y < P * L) hw = mix(qw, W, p.y / (P * L));
    else hw = mix(W, tw, (p.y - P * L) / (L - P * L));
    float d = min(hw - abs(p.x), min(p.y + Q, L - p.y));
    d = max(d, moyeu - length(p));
    if (boule > 0.0) d = max(d, boule - length(p - vec2(0.0, -yb)));
    float a = clamp(d / flou + 0.5, 0.0, 1.0);
    vec3 c = vec3(r, g, b) + facette * (p.x < 0.0 ? 1.0 : -0.3);
    gl_FragColor = texture2D(Texture, TexCoord) * vec4(c, a * alpha);
  }
]]

-- Disque lisse avec degrade radial de c1 (centre) a c2 (bord)
local shader_disque = resource.create_shader[[
  #ifdef GL_ES
  precision mediump float;
  #endif
  uniform sampler2D Texture;
  varying vec2 TexCoord;
  uniform float r1, g1, b1, r2, g2, b2, px;
  void main() {
    float d = length((TexCoord - vec2(0.5)) * 2.0);
    float a = clamp((1.0 - d) / px + 0.5, 0.0, 1.0);
    vec3 c = mix(vec3(r1, g1, b1), vec3(r2, g2, b2), d);
    gl_FragColor = texture2D(Texture, TexCoord) * vec4(c, a);
  }
]]

local function disque(x, y, rayon, c1, c2)
  shader_disque:use{
    r1 = c1[1], g1 = c1[2], b1 = c1[3], r2 = c2[1], g2 = c2[2], b2 = c2[3],
    px = 1.2 / rayon,
  }
  tex_blanc:draw(x - rayon, y - rayon, x + rayon, y + rayon)
  shader_disque:deactivate()
end

-- Cache du pivot : acier noirci avec un leger reflet
local function moyeu(x, y, rayon)
  disque(x, y, rayon, {0.06, 0.06, 0.06}, {0.03, 0.03, 0.03})
  disque(x, y, rayon * 0.75, {0.30, 0.29, 0.27}, {0.14, 0.13, 0.12})
  disque(x, y, rayon * 0.30, {0.02, 0.02, 0.02}, {0.02, 0.02, 0.02})
end

local function aiguille(x, y, angle, h, c, alpha, flou, facette)
  local larg = math.max(h.W, h.qw, h.boule or 0, h.moyeu or 0) + 4
  local bas  = h.Q + (h.boule or 0) + 4
  gl.pushMatrix()
  gl.translate(x, y)
  gl.rotate(angle, 0, 0, 1)
  shader_aiguille:use{
    x0 = -larg, x1 = larg, y0 = -bas, y1 = h.L + 4,
    L = h.L, Q = h.Q, W = h.W, P = h.P, qw = h.qw, tw = h.tw,
    boule = h.boule or 0, yb = h.yb or 0, moyeu = h.moyeu or 0,
    r = c[1], g = c[2], b = c[3], alpha = alpha or 1,
    flou = flou or 1, facette = facette or 0,
  }
  tex_blanc:draw(-larg, -(h.L + 4), larg, bas)
  shader_aiguille:deactivate()
  gl.popMatrix()
end

-- Aiguille avec son ombre portee douce sur le cadran
local function aiguille_ombre(x, y, angle, h, s)
  aiguille(x + 3 * s, y + 5 * s, angle, h, {0, 0, 0}, 0.30, 3 * s, 0)
  aiguille(x, y, angle, h, NOIR, 1, 1, 0.10)
end

-- Dimensions en pixels de l'image (P = proportion, sans unite)
local AIG_HEURE   = {L = 196, Q = 40, W = 8.4, P = 0.30, qw = 3.4, tw = 0.7, moyeu = 12}
local AIG_MINUTE  = {L = 316, Q = 48, W = 6.6, P = 0.26, qw = 2.9, tw = 0.5, moyeu = 11}
local AIG_SECONDE = {L = 330, Q = 76, W = 1.3, P = 0.05, qw = 1.9, tw = 0.7, boule = 8.6, yb = 58, moyeu = 7}
local AIG_COMPTEUR = {L = 80, Q = 18, W = 3.4, P = 0.22, qw = 2.0, tw = 0.45}

local function echelle(h, s)
  local r = {}
  for n, v in pairs(h) do r[n] = (n == "P") and v or v * s end
  return r
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
-- Rendu
------------------------------------------------------------------------

function node.render()
  gl.clear(0, 0, 0, 1)

  local t   = os.time()
  local fr  = fraction(t)
  local utc = os.date("!*t", t)
  local d   = os.date("!*t", t + decalage(utc))

  local s = HEIGHT * TAILLE / IMAGE           -- pixels ecran par pixel image
  local ox = WIDTH / 2 - BOITIER[1] * s
  local oy = HEIGHT / 2 - BOITIER[2] * s
  local function ecran(p) return ox + p[1] * s, oy + p[2] * s end

  -- Disque de lune sous le cadran : demi-tour par lunaison, pleine lune en haut
  local lx, ly = ecran(AXE_LUNE)
  local R = RAYON_LUNE * s
  gl.pushMatrix()
  gl.translate(lx, ly)
  gl.rotate(-90 + age_lune(t) / LUNAISON * 180, 0, 0, 1)
  lune:draw(-R, -R, R, R)
  gl.popMatrix()

  fond:draw(ox, oy, ox + IMAGE * s, oy + IMAGE * s)

  -- Jours (dimanche en haut, 7 secteurs) et quantieme (31 en haut)
  local x, y = ecran(AXE_JOURS)
  aiguille_ombre(x, y, (d.wday - 1) * 360 / 7, echelle(AIG_COMPTEUR, s), s)
  moyeu(x, y, 8 * s)
  x, y = ecran(AXE_DATES)
  aiguille_ombre(x, y, (d.day % 31) * 360 / 31, echelle(AIG_COMPTEUR, s), s)
  moyeu(x, y, 8 * s)

  -- Heures, minutes, trotteuse
  x, y = ecran(AXE)
  local sec = d.sec + (balayage and math.floor(fr * 8) / 8 or 0)
  local m = d.min + sec / 60
  local h = (d.hour % 12) + m / 60
  aiguille_ombre(x, y, h * 30, echelle(AIG_HEURE, s), s)
  aiguille_ombre(x, y, m * 6, echelle(AIG_MINUTE, s), s)
  if trotteuse then
    aiguille_ombre(x, y, sec * 6, echelle(AIG_SECONDE, s), s)
  end
  moyeu(x, y, 9 * s)
end

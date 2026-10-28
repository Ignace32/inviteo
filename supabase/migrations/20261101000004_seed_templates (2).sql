-- ============================================================================
-- Invitéo — migration 4/5 : modèles de départ (phase 3)
--
-- Un modèle est une ligne de données. La page animée (phase 4) et le PDF
-- (phase 5) lisent cette configuration : aucun modèle n'est codé « en dur » pour
-- un invité. Pour ajouter un modèle plus tard : INSERT d'une nouvelle ligne
-- (ou un nouveau fichier de migration), sans toucher au reste de l'architecture.
--
-- Clés de config :
--   palette   : couleurs (bg, paper, text, muted, accent)
--   fonts     : polices (display, body)
--   ornament  : décor prévu pour la phase 4 (floral-fine, floral-soft, none, laurel, rule)
--   layout    : structure de page (centered, minimal, photo-hero, academic, clean)
--   cover     : style de l'ouverture animée (envelope, ticket, curtain, seal)
--   photos    : nombre de photos conseillé (min/max)
-- Aucun dégradé décoratif : toutes les couleurs sont des aplats.
-- ============================================================================

insert into public.templates (slug, name, event_type, description, config) values
('mariage-classique', 'Mariage classique', 'wedding',
 'Ivoire, fleurs délicates et détails dorés.',
 '{"palette":{"bg":"#FAF7F1","paper":"#FFFFFF","text":"#25221F","muted":"#6B655E","accent":"#B8915A"},
   "fonts":{"display":"Fraunces","body":"DM Sans"},
   "ornament":"floral-fine","layout":"centered","cover":"envelope","photos":{"min":1,"max":6}}'),

('mariage-moderne', 'Mariage moderne', 'wedding',
 'Noir, doré et typographie minimaliste.',
 '{"palette":{"bg":"#171513","paper":"#25221F","text":"#FAF7F1","muted":"#C9C3BA","accent":"#C9A24D"},
   "fonts":{"display":"DM Sans","body":"DM Sans"},
   "ornament":"none","layout":"minimal","cover":"curtain","photos":{"min":1,"max":6}}'),

('anniversaire-elegant', 'Anniversaire élégant', 'birthday',
 'La photo de la personne fêtée en vedette, couleurs festives.',
 '{"palette":{"bg":"#25221F","paper":"#FAF7F1","text":"#FAF7F1","muted":"#C9C3BA","accent":"#E86D32"},
   "fonts":{"display":"Fraunces","body":"DM Sans"},
   "ornament":"rule","layout":"photo-hero","cover":"ticket","photos":{"min":1,"max":4}}'),

('bapteme', 'Baptême', 'baptism',
 'Blanc, tons doux et éléments floraux.',
 '{"palette":{"bg":"#FFFFFF","paper":"#FAF7F1","text":"#25221F","muted":"#6B655E","accent":"#8FA6BF"},
   "fonts":{"display":"Fraunces","body":"DM Sans"},
   "ornament":"floral-soft","layout":"centered","cover":"envelope","photos":{"min":1,"max":4}}'),

('remise-diplome', 'Remise de diplôme', 'graduation',
 'Bleu marine, doré et présentation académique.',
 '{"palette":{"bg":"#14284B","paper":"#FAF7F1","text":"#FAF7F1","muted":"#C5CCDA","accent":"#C9A24D"},
   "fonts":{"display":"Fraunces","body":"DM Sans"},
   "ornament":"laurel","layout":"academic","cover":"seal","photos":{"min":0,"max":3}}'),

('evenement-professionnel', 'Événement professionnel', 'corporate',
 'Design épuré, moderne et institutionnel.',
 '{"palette":{"bg":"#FAF7F1","paper":"#FFFFFF","text":"#25221F","muted":"#6B655E","accent":"#E86D32"},
   "fonts":{"display":"DM Sans","body":"DM Sans"},
   "ornament":"rule","layout":"clean","cover":"curtain","photos":{"min":0,"max":3}}');

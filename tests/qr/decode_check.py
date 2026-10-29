"""Décode chaque QR généré avec OpenCV (lecteur indépendant) et compare au texte d'origine.

Deux décodeurs sont utilisés :
  * le détecteur « classique » d'OpenCV, connu pour échouer sur certains codes de grande
    taille même lorsqu'ils sont conformes (résultat affiché pour information) ;
  * le détecteur basé sur Aruco (OpenCV >= 4.8), plus robuste : TOUS les codes doivent
    être décodés correctement par lui, sinon le test échoue.
Les codes d'invitation Invitéo (une URL d'environ 80 caractères) tiennent en version 5 ou 6.
"""
import json, sys
import numpy as np, cv2

data = json.load(open(sys.argv[1], encoding='utf-8'))


def image_of(o, scale, border=4):
    n = o['size']
    img = np.full(((n + 2 * border) * scale,) * 2, 255, np.uint8)
    for y, row in enumerate(o['rows']):
        for x, c in enumerate(row):
            if c == '1':
                img[(y + border) * scale:(y + border + 1) * scale, (x + border) * scale:(x + border + 1) * scale] = 0
    return img


classic = cv2.QRCodeDetector()
aruco = cv2.QRCodeDetectorAruco() if hasattr(cv2, 'QRCodeDetectorAruco') else None
if aruco is None:
    print("OpenCV sans QRCodeDetectorAruco : installez OpenCV >= 4.8 pour ce test.")
    sys.exit(2)

ok = bad = skipped = classic_ok = 0
versions, fails = set(), []
for o in data:
    if 'error' in o:
        skipped += 1
        continue
    if classic.detectAndDecode(image_of(o, 8))[0] == o['text']:
        classic_ok += 1
    good = any(aruco.detectAndDecode(image_of(o, s))[0] == o['text'] for s in (8, 12))
    if good:
        ok += 1
        versions.add(o['version'])
    else:
        bad += 1
        fails.append((o['level'], o['version'], len(o['text'])))

print(f'décodés (détecteur robuste) : {ok} | échecs : {bad} | trop longs (refus attendu) : {skipped}')
print(f'pour information, détecteur classique : {classic_ok} sur {ok + bad}')
print('versions couvertes :', sorted(versions))
if fails:
    print('échecs (niveau, version, longueur) :', fails[:15])
sys.exit(1 if bad else 0)

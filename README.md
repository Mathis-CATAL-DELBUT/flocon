# Flocon ❄️

De la neige qui tombe sur le bureau de ton Mac, s'accumule sur les fenêtres et au-dessus du Dock, glisse quand tu déplaces une fenêtre… et forme des bonshommes de neige.

App native macOS (Swift + Metal), légère, qui vit dans la barre des menus.

## Installation

Il faut macOS 14 (Sonoma) ou plus récent, sur un Mac Apple Silicon ou Intel.

1. Télécharge `Flocon.zip` depuis la page [Releases](https://github.com/Mathis-CATAL-DELBUT/flocon/releases/latest), puis décompresse-le.
2. Glisse `Flocon.app` dans le dossier **Applications**.
3. Ouvre l'app. Elle n'est pas signée par un développeur Apple, donc macOS la bloque la première fois. Va dans **Réglages Système › Confidentialité et sécurité**, puis clique sur **Ouvrir quand même** en bas de la page.
   Ou, dans le Terminal :
   ```bash
   xattr -dr com.apple.quarantine /Applications/Flocon.app
   ```
4. Un flocon ❄️ apparaît dans la barre des menus : c'est là que se trouvent les réglages. Pour la lancer à chaque démarrage du Mac, coche « Ouvrir au démarrage ».

Pour la compiler toi-même : voir [Compiler](#compiler).

## Fonctionnalités

- **Chute de neige** avec profondeur (petits flocons lointains, gros flocons proches, quelques cristaux à 6 branches qui tournent), oscillation et vent avec rafales.
- **Accumulation** sur le haut des fenêtres (en suivant leurs coins arrondis) et sur le Dock, seulement là où il est. La neige se tasse, déborde des bords et ne s'accumule pas là où une autre fenêtre la cache. La fenêtre de devant reçoit le plus de neige, celles du fond un peu moins.
- **Glissement** : déplace une fenêtre et sa neige tombe, d'autant plus vite que tu la bouges vite. Rétrécis-la et la neige qui dépasse du nouveau bord tombe.
- **Fais ton bonhomme de neige**, sans cliquer : maintiens ⌥ (Option) et glisse le curseur le long de la neige (Dock ou haut d'une fenêtre). Une boule se forme et grossit en roulant. Monte le curseur pour la porter, pose-la sur une autre surface ou lâche ⌥ au-dessus d'une boule plus grosse pour l'empiler. Lâche ⌥ en bougeant pour la lancer : de haut, elle éclate en neige, sinon elle roule. Rappuie sur ⌥ quand le curseur est sur elle pour la rattraper en l'air. Avec plusieurs écrans, elle passe de l'un à l'autre, lancée ou portée. À trois boules, le visage, le chapeau, l'écharpe et les bras apparaissent. Les bonshommes suivent la fenêtre qui les porte et s'effondrent si on la secoue. Pour en faire tomber un : ⌥ + un coup de curseur rapide à travers lui (ou « Faire tomber les bonshommes de neige » dans le menu).
- **Bonshommes automatiques** (option) sur le Dock quand il y a assez de neige, ou à la demande depuis le menu.
- **Déblayer** (⌥C, depuis n'importe quelle app) : une tractopelle traverse le bas de l'écran et pousse la neige du Dock hors de l'écran. La neige des fenêtres tombe.
- **Curseur** : il trace un sillon dans la neige en la repoussant sur les côtés, soulève une fine poudre et emporte les flocons dans son sillage.
- Les clics traversent toujours la neige. En plein écran (Dock caché), elle tombe aussi et s'accumule au bas de l'écran ; la neige du bureau attend ton retour. Option « Neige en plein écran » pour la masquer. Pause quand l'écran est en veille.
- **Économie d'énergie** sur batterie et en mode économie d'énergie : 30 images/s et moitié moins de flocons.
- Fonctionne sur plusieurs écrans.

## Consommation

Mesurée sur un MacBook Pro 14" (écran Retina 3024×1964), intensité moyenne :

| État | Mémoire (empreinte) | CPU |
|---|---|---|
| Neige active | ~80 Mo | 3 à 6 % |
| En pause / écran en veille | ~15 à 35 Mo | 0 % |

Sur ces ~80 Mo, environ 50 Mo sont alloués par macOS (WindowServer) pour composer n'importe quel calque animé transparent en plein écran. Un test minimal qui affiche un seul triangle donne le même chiffre. Le reste correspond au rendu en 1x (4 fois moins de mémoire qu'en Retina, invisible sur des flocons) et aux tampons réutilisés sans allocation à chaque frame. Le rendu Retina est disponible dans le menu (environ +35 Mo).

Aucune permission n'est nécessaire : Flocon lit seulement la position des fenêtres, pas leur contenu. La largeur du Dock est estimée à partir de ses réglages ; pour qu'elle soit exacte, autorise Flocon dans Accessibilité (option dans le menu). Il ne lit alors que la taille du Dock.

## Compiler

Prérequis : macOS 14 ou plus récent, Xcode ou les Command Line Tools.

```bash
./build.sh             # architecture de ce Mac
./build.sh universal   # Apple Silicon + Intel
open build/Flocon.app
```

Copie ensuite `build/Flocon.app` dans `/Applications`. L'app est signée « ad hoc » : sur un autre Mac, macOS la bloque au premier lancement (voir [Installation](#installation)).

Mode démo, pour les captures d'écran : `FLOCON_DEMO=1 FLOCON_DEMO_X=600 build/Flocon.app/Contents/MacOS/Flocon` construit un bonhomme de neige dès le lancement.

## Structure

| Fichier | Rôle |
|---|---|
| `Sources/Snowfield.swift` | Simulation d'un écran : flocons, tas de neige, glissement, bonshommes, curseur |
| `Sources/Pile.swift` | Tas de neige 1D (hauteur par colonne de 2 pt, tassement) |
| `Sources/Dock.swift` | Position et largeur du Dock |
| `Sources/WindowTracker.swift` | Position des fenêtres visibles (`CGWindowListCopyWindowInfo`) |
| `Sources/Renderer.swift` | Rendu Metal (sprites instanciés + maillage des tas) et shaders |
| `Sources/Overlay.swift` | Fenêtre transparente plein écran, display link |
| `Sources/AppDelegate.swift` | Menu, écrans, batterie, veille |
| `Sources/Settings.swift` | Réglages (UserDefaults) |

## Licence

[MIT](LICENSE)

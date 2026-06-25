import Foundation

/// Real chapter HTML + CSS pulled from the Pinocchio EPUB the user
/// reads on-device (Project Gutenberg Ebookmaker output), so reader
/// formatting tests run against the ACTUAL book markup, not a
/// synthetic fixture. Body <p> are text-align:justify; the chapter
/// title is an <h2>. There are NO class="center" paragraphs in the body.
enum PinocchioFixture {
    static let chapter3HTML = #"""
<?xml version='1.0' encoding='utf-8'?>

<html xmlns="http://www.w3.org/1999/xhtml" lang="it">
<head>
<meta charset="utf-8"/><title>
  Le avventure di Pinocchio, di Carlo Collodi
 </title>
<link href="5102908906001652230_cover.jpg" rel="icon" type="image/x-cover" id="id-1601837862811286748"/>

<link href="0.css" rel="stylesheet" type="text/css"/>
<link href="1.css" rel="stylesheet" type="text/css"/>
<link href="pgepub.css" rel="stylesheet" type="text/css"/>
<meta name="generator" content="Ebookmaker 0.13.9 by Project Gutenberg"/>
</head>
<body class="x-ebookmaker x-ebookmaker-3"><div class="chapter">
<p>
<span class="x-ebookmaker-pageno" id="Page_5" title="[5]"></span>
</p>
<div class="figcenter"><a id="fill5"/>
<img alt="" src="5102908906001652230_ill5.jpg" id="img_images_ill5.jpg"/>
</div>
<h2 id="capI">I.
<span class="smaller">Come andò che Maestro Ciliegia, falegname
trovò un pezzo di legno che piangeva e rideva come un bambino.</span></h2>
</div>
<p>
— C'era una volta....
</p>
<p>
— Un re! — diranno subito i miei piccoli lettori.
</p>
<p>
— No, ragazzi, avete sbagliato. C'era una volta
un pezzo di legno.
</p>
<p>
Non era un legno di lusso, ma un semplice
pezzo da catasta, di quelli che d'inverno si mettono
nelle stufe e nei caminetti per accendere
il fuoco e per riscaldare le stanze.
</p>
<p>
<span class="x-ebookmaker-pageno" id="Page_6" title="[6]"></span>
</p>
<p>
Non so come andasse, ma il fatto gli è che un
bel giorno questo pezzo di legno capitò nella bottega
di un vecchio falegname, il quale aveva
nome mastr'Antonio, se non che tutti lo chiamavano
maestro Ciliegia, per via della punta del
suo naso, che era sempre lustra e paonazza, come
una ciliegia matura.
</p>
<div class="figcenter" role="figure" aria-labelledby="ebm_caption0"><a id="fill6"/>
<img alt="" src="5102908906001652230_ill6.jpg" id="img_images_ill6.jpg"/>
<p class="caption" id="ebm_caption0">.... sentì una vocina sottile sottile.</p>
</div>
<p>
Appena maestro Ciliegia ebbe visto quel pezzo
di legno, si rallegrò tutto; e dandosi una fregatina
di mani per la contentezza, borbottò a mezza voce:
</p>
<p>
— Questo legno è capitato a tempo; voglio
servirmene per fare una gamba di tavolino. —
</p>
<p>
<span class="x-ebookmaker-pageno" id="Page_7" title="[7]"></span>
</p>
<p>
Detto fatto, prese subito l'ascia arrotata per
cominciare a levargli la scorza e a digrossarlo;
ma quando fu lì per lasciare andare la prima
asciata, rimase col braccio sospeso in aria, perchè
sentì una vocina sottile sottile, che disse
raccomandandosi:
</p>
<p>
— Non mi picchiar tanto forte! —
</p>
<p>
Figuratevi come rimase quel buon vecchio di
maestro Ciliegia!
</p>
<p>
Girò gli occhi smarriti intorno alla stanza per
vedere di dove mai poteva essere uscita quella vocina,
e non vide nessuno! Guardò sotto il banco,
e nessuno: guardò dentro un armadio che stava
sempre chiuso, e nessuno; guardò nel corbello
dei trucioli e della segatura, e nessuno; aprì l'uscio
di bottega per dare un'occhiata anche sulla strada,
e nessuno. O dunque?...
</p>
<p>
— Ho capito; — disse allora ridendo e grattandosi
la parrucca — si vede che quella vocina
me la son figurata io. Rimettiamoci a lavorare. —
</p>
<p>
E ripresa l'ascia in mano, tirò giù un solennissimo
colpo sul pezzo di legno.
</p>
<p>
— Ohi! tu m'hai fatto male! — gridò rammaricandosi
la solita vocina.
</p>
<p>
Questa volta maestro Ciliegia restò di stucco,
cogli occhi fuori del capo per la paura, colla bocca
<span class="x-ebookmaker-pageno" id="Page_8" title="[8]"></span>
spalancata e colla lingua giù ciondoloni fino al
mento, come un mascherone da fontana.
</p>
<p>
Appena riebbe l'uso della parola, cominciò a
dire tremando e balbettando dallo spavento:
</p>
<p>
— Ma di dove sarà uscita questa vocina che
ha detto ohi?... Eppure qui non c'è anima viva.
Che sia per caso questo pezzo di legno che abbia
imparato a piangere e a lamentarsi come un bambino?
Io non lo posso credere. Questo legno eccolo
qui; è un pezzo di legno da caminetto, come tutti
gli altri, e a buttarlo sul fuoco, c'è da far bollire
una pentola di fagioli.... O dunque? Che ci sia nascosto
dentro qualcuno? Se c'è nascosto qualcuno,
tanto peggio per lui. Ora l'accomodo io! —
</p>
<p>
E così dicendo, agguantò con tutt'e due le
mani quel povero pezzo di legno, e si pose a
sbatacchiarlo senza carità contro le pareti della
stanza.
</p>
<p>
Poi si messe in ascolto, per sentire se c'era
qualche vocina che si lamentasse. Aspettò due
minuti, e nulla; cinque minuti, e nulla; dieci minuti,
e nulla!
</p>
<p>
— Ho capito — disse allora sforzandosi di ridere
e arruffandosi la parrucca — si vede che quella
vocina che ha detto <i>ohi</i>, me la son figurata io!
Rimettiamoci a lavorare. —
</p>
<p>
E perchè gli era entrato addosso una gran
<span class="x-ebookmaker-pageno" id="Page_9" title="[9]"></span>
paura, si provò a canterellare per farsi un po' di
coraggio.
</p>
<p>
Intanto, posata da una parte l'ascia, prese in
mano la pialla, per piallare e tirare a pulimento
il pezzo di legno; ma nel mentre che lo piallava
in su e in giù, sentì la solita vocina che gli disse
ridendo:
</p>
<p>
— Smetti! tu mi fai il pizzicorino sul corpo! —
</p>
<p>
Questa volta il povero maestro Ciliegia cadde
giù come fulminato. Quando riaprì gli occhi, si
trovò seduto per terra.
</p>
<p>
Il suo viso pareva trasfigurito, e perfino la punta
del naso, di paonazza come era quasi sempre, gli
era diventata turchina dalla gran paura.
</p>
</body></html>

"""#

    static let chapter3CSS = #"""
@media screen {
    body {
        margin-left: 10%;
        margin-right: 10%
        }
    }
.pagedjs_page_content > div {
    margin-left: 10%;
    margin-right: 10%
    }
p {
    margin-top: 0;
    margin-bottom: 0;
    line-height: 1.5;
    text-align: justify;
    text-indent: 1.5em
    }
.center {
    text-align: center;
    text-indent: 0
    }
.lapide {
    text-align: center;
    text-indent: 0;
    line-height: 2em;
    font-size: 80%;
    margin: 2em auto
    }
div.booktitle {
    page-break-before: always;
    padding: 3em
    }
div.titlepage {
    text-align: center;
    margin: 0 5%;
    padding: 2em 0;
    page-break-before: always;
    page-break-after: always
    }
div.titlepage p {
    text-align: inherit;
    text-indent: 0
    }
div.verso {
    text-align: center;
    padding-top: 2em;
    font-size: 95%;
    margin: 0 10%
    }
div.verso p {
    text-align: inherit;
    text-indent: 0
    }
div.somm {
    page-break-before: always;
    padding-top: 3em
    }
div.somm p {
    text-indent: 0
    }
div.chapter {
    page-break-before: always;
    padding-top: 3em
    }
div.chapter h2 {
    page-break-before: avoid
    }
h1, h2 {
    text-align: center;
    font-style: normal;
    font-weight: normal;
    line-height: 1.5
    }
h1 {
    font-size: 150%
    }
h2 {
    font-size: 140%;
    margin-top: 1em;
    margin-bottom: 2em;
    page-break-before: avoid
    }
span.smaller {
    display: block;
    font-size: 68%;
    margin: 0.5em 5%;
    line-height: 1.2em
    }
hr {
    width: 70%;
    margin-top: 1em;
    margin-bottom: 1em;
    margin-left: 15%;
    margin-right: 15%;
    clear: both
    }
hr.mid {
    width: 50%;
    margin-left: 25%;
    margin-right: 25%
    }
hr.silver {
    width: 90%;
    margin-left: 5%;
    margin-right: 5%;
    border-top: none;
    border-right: none;
    border-bottom: thin solid silver;
    border-left: none
    }
@media handheld {
    hr.silver {
        display: none
        }
    }
.pagenum {
    font-style: normal;
    font-weight: normal;
    text-decoration: none;
    font-size: 65%;
    text-align: right;
    color: #999;
    background-color: #fff;
    clear: left
    }
.pad4 {
    margin-top: 4em
    }
.pad2 {
    margin-top: 2em
    }
.pad1 {
    margin-top: 1em
    }
.small {
    font-size: 85%
    }
.large {
    font-size: 115%
    }
.x-large {
    font-size: 130%
    }
.main-t {
    font-size: 200%
    }
.smcap {
    font-variant: small-caps
    }
table {
    margin: auto;
    border-collapse: collapse
    }
.indice {
    line-height: 1em;
    margin-top: 2em;
    font-size: 90%
    }
.indice td {
    vertical-align: top;
    padding-left: 1.5em;
    text-indent: -1em;
    padding-top: 0.5em
    }
.indice td.cap {
    text-align: right;
    vertical-align: top;
    white-space: nowrap;
    padding-right: 0.5em
    }
.indice td.pag {
    text-align: right;
    vertical-align: bottom;
    white-space: nowrap
    }
.figcenter {
    text-align: center;
    margin: 2em auto;
    clear: both;
    max-width: 100%
    }
img {
    max-width: 100%;
    height: auto
    }
.caption {
    text-align: center;
    font-size: 80%;
    text-indent: 0;
    margin: 0.25em 0
    }
.tnote {
    background-color: #f7f1e3;
    color: #000;
    padding: 1em 1em 2em 1em;
    margin: 3em 10%;
    font-family: sans-serif;
    font-size: 90%;
    page-break-before: always
    }
.tntitle {
    text-align: center;
    text-indent: 0;
    padding: 1em;
    font-size: 120%;
    margin-bottom: 1em
    }
.tnote p {
    padding: 0 1em;
    text-indent: 0;
    line-height: 1.2em
    }
.poem {
    text-align: left;
    font-size: 95%;
    margin: 1.5em 10%
    }
.poem p {
    margin: 0;
    padding-left: 3em;
    text-indent: -3em
    }

@charset "utf-8";
body, body.tei.tei-text {
    color: black;
    background-color: white;
    width: auto;
    border: 0;
    padding: 0
    }
div, p, pre, h1, h2, h3, h4, h5, h6 {
    margin-left: 0;
    margin-right: 0;
    display: block
    }
section.pgheader {
    page-break-after: always
    }
section.pgfooter {
    page-break-before: always
    }
div.pgebub-root-div {
    margin: 0
    }
h2 {
    page-break-before: always;
    padding-top: 1em
    }
div.figcenter span.caption {
    display: block
    }
.pgmonospaced {
    font-family: monospace;
    font-size: 0.9em
    }
a.pgkilled {
    text-decoration: none
    }
.x-ebookmaker-cover {
    background-color: grey;
    text-align: center;
    padding: 0;
    margin: 0;
    page-break-after: always;
    text-indent: 0;
    width: 100%;
    height: 100%
    }
body.x-ebookmaker-coverpage {
    margin: 0;
    padding: 0
    }
body.x-ebookmaker.x-ebookmaker-3 .pgshow {
    visibility: visible;
    display: initial
    }

#pg-header div, #pg-footer div {
    all: initial;
    display: block;
    margin-top: 1em;
    margin-bottom: 1em;
    margin-left: 2em
    }
#pg-footer div.agate {
    font-size: 90%;
    margin-top: 0;
    margin-bottom: 0;
    text-align: center
    }
#pg-footer li {
    all: initial;
    display: block;
    margin-top: 1em;
    margin-bottom: 1em;
    text-indent: -0.6em
    }
#pg-footer div.secthead {
    font-size: 110%;
    font-weight: bold
    }
#pg-footer #project-gutenberg-license {
    font-size: 110%;
    margin-top: 0;
    margin-bottom: 0;
    text-align: center
    }
#pg-header-heading {
    all: inherit;
    text-align: center;
    font-size: 120%;
    font-weight: bold
    }
#pg-footer-heading {
    all: inherit;
    text-align: center;
    font-size: 120%;
    font-weight: normal;
    margin-top: 0;
    margin-bottom: 0
    }
#pg-header #pg-machine-header p {
    text-indent: -4em;
    margin-left: 4em;
    margin-top: 1em;
    margin-bottom: 0;
    font-size: medium
    }
#pg-header #pg-header-authlist {
    all: initial;
    margin-top: 0;
    margin-bottom: 0
    }
#pg-header #pg-machine-header strong {
    font-weight: normal
    }
#pg-header #pg-start-separator, #pg-footer #pg-end-separator {
    margin-bottom: 3em;
    margin-left: 0;
    margin-right: auto;
    margin-top: 2em;
    text-align: center
    }
.xhtml_center {
    text-align: center;
    display: block
    }
.xhtml_center table {
    display: table;
    text-align: left;
    margin-left: auto;
    margin-right: auto
    }
"""#
}

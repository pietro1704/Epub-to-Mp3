# Vendored pdf-extract

Source: pdf-extract 0.12.1 from the crates.io registry (the version previously
locked in `Cargo.lock`), upstream commit
`47b792ba04c5f3b6e478072b2efb8e1a2a06ec7e`.
Repository: https://github.com/jrmuizel/pdf-extract

Upstream Cargo package metadata declares the MIT license and names the author.
The published crate has no license file or copyright notice, and none was found
at the top level of the upstream repository on 2026-11-26. The declaration is
preserved unchanged in `Cargo.toml` and `Cargo.toml.orig`.

Local change: Form XObject handling only. A Form now inherits the current CTM,
applies its `/Matrix`, and drops glyphs outside its `/BBox` and the page box.
Page content that is not inside a Form is unchanged. Without this, a PDF whose
pages are halves of a shared spread yields the whole spread on every page.
Regression coverage: `crates/converter-core/tests/pdf_form_spread.rs`.

```diff
diff --git a/native/vendor/pdf-extract/src/lib.rs b/native/vendor/pdf-extract/src/lib.rs
index 42ad338de5c..038ac48ab97 100644
--- a/native/vendor/pdf-extract/src/lib.rs
+++ b/native/vendor/pdf-extract/src/lib.rs
@@ -1271,6 +1271,24 @@ struct GraphicsState<'a>
     stroke_colorspace: ColorSpace,
     stroke_color: Vec<f64>,
     line_width: f64,
+    // Visible area in page space while drawing a Form XObject; `None` for page content.
+    form_clip: Option<MediaBox>,
+}
+
+/// The part of `area` covered by a Form's /BBox once placed by `ctm`.
+fn clip_to_bbox(area: MediaBox, bbox: &[f64], ctm: &Transform) -> MediaBox {
+    let corners = [(bbox[0], bbox[1]), (bbox[2], bbox[1]), (bbox[0], bbox[3]), (bbox[2], bbox[3])]
+        .map(|(x, y)| ctm.transform_point(point2(x, y)));
+    let xs = corners.map(|p| p.x);
+    let ys = corners.map(|p| p.y);
+    let min = |v: [f64; 4]| v.iter().copied().fold(f64::INFINITY, f64::min);
+    let max = |v: [f64; 4]| v.iter().copied().fold(f64::NEG_INFINITY, f64::max);
+    MediaBox {
+        llx: area.llx.max(min(xs)),
+        lly: area.lly.max(min(ys)),
+        urx: area.urx.min(max(xs)),
+        ury: area.ury.min(max(ys)),
+    }
 }
 
 fn show_text(gs: &mut GraphicsState, s: &[u8],
@@ -1311,7 +1329,14 @@ fn show_text(gs: &mut GraphicsState, s: &[u8],
         let is_space = c == 32 && length == 1;
         if is_space { spacing += ts.word_spacing }
 
-        output.output_character(&trm, w0, spacing, ts.font_size, &font.decode_char(c))?;
+        // A glyph is visible when the middle of its advance is inside the Form clip.
+        let visible = gs.form_clip.map_or(true, |clip| {
+            let middle = trm.transform_point(point2(w0 * ts.font_size / 2., 0.));
+            middle.x >= clip.llx && middle.x <= clip.urx && middle.y >= clip.lly && middle.y <= clip.ury
+        });
+        if visible {
+            output.output_character(&trm, w0, spacing, ts.font_size, &font.decode_char(c))?;
+        }
         let tj = 0.;
         let ty = 0.;
         let tx = ts.horizontal_scaling * ((w0 - tj/1000.)* ts.font_size + spacing);
@@ -1578,7 +1603,7 @@ impl<'a> Processor<'a> {
         Processor { font_table: HashMap::new(), _none: PhantomData }
     }
 
-    fn process_stream(&mut self, doc: &'a Document, content: Vec<u8>, resources: &'a Dictionary, media_box: &MediaBox, output: &mut dyn OutputDev, page_num: u32) -> Result<(), OutputError> {
+    fn process_stream(&mut self, doc: &'a Document, content: Vec<u8>, resources: &'a Dictionary, media_box: &MediaBox, ctm: Transform, form_clip: Option<MediaBox>, output: &mut dyn OutputDev, page_num: u32) -> Result<(), OutputError> {
         let content = Content::decode(&content).unwrap();
         let mut gs: GraphicsState = GraphicsState {
             ts: TextState {
@@ -1596,7 +1621,8 @@ impl<'a> Processor<'a> {
             stroke_color: Vec::new(),
             stroke_colorspace: ColorSpace::DeviceGray,
             line_width: 1.,
-            ctm: Transform2D::identity(),
+            ctm,
+            form_clip,
             smask: None
         };
         //let mut ts = &mut gs.ts;
@@ -1865,7 +1891,18 @@ impl<'a> Processor<'a> {
                     let xf: &Stream = get(&doc, xobject, name);
                     let resources = maybe_get_obj(&doc, &xf.dict, b"Resources").and_then(|n| n.as_dict().ok()).unwrap_or(resources);
                     let contents = get_contents(xf);
-                    self.process_stream(&doc, contents, resources, &media_box, output, page_num)?;
+                    // A Form is placed by its /Matrix over the current CTM and clipped
+                    // by its /BBox and the page box.
+                    let numbers = |key: &[u8], len: usize| maybe_get_array(doc, &xf.dict, key)
+                        .filter(|a| a.len() == len)
+                        .map(|a| a.iter().map(|o| as_num(maybe_deref(doc, o))).collect::<Vec<f64>>());
+                    let ctm = match numbers(b"Matrix", 6) {
+                        Some(m) => gs.ctm.pre_transform(&Transform2D::row_major(m[0], m[1], m[2], m[3], m[4], m[5])),
+                        None => gs.ctm,
+                    };
+                    let area = gs.form_clip.unwrap_or(*media_box);
+                    let clip = numbers(b"BBox", 4).map_or(area, |bbox| clip_to_bbox(area, &bbox, &ctm));
+                    self.process_stream(&doc, contents, resources, &media_box, ctm, Some(clip), output, page_num)?;
                 }
                 _ => { dlog!("unknown operation {:?}", operation); }
 
@@ -2415,7 +2452,7 @@ fn output_doc_inner<'a>(page_num: u32, object_id: ObjectId, doc: &'a Document, p
     let art_box = get::<Option<Vec<f64>>>(&doc, page_dict, b"ArtBox")
         .map(|x| (x[0], x[1], x[2], x[3]));
     output.begin_page(page_num, &media_box, art_box)?;
-    p.process_stream(&doc, doc.get_page_content(object_id).unwrap(), resources, &media_box, output, page_num)?;
+    p.process_stream(&doc, doc.get_page_content(object_id).unwrap(), resources, &media_box, Transform2D::identity(), None, output, page_num)?;
     output.end_page()?;
     Ok(())
 }
```

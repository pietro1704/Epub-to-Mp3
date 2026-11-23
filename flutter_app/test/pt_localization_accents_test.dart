import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Portuguese strings must keep their diacritics (A8: "esta vazia", "nao podem").
void main() {
  test('pt strings never use the unaccented spelling of common words', () {
    final arb = jsonDecode(File('lib/l10n/app_pt.arb').readAsStringSync()) as Map<String, dynamic>;
    // Words that exist only with an accent in Portuguese, or whose unaccented
    // form is a different word used wrongly here ("esta vazia", "nao").
    final forbidden = RegExp(
      r'\b(nao|voce|voces|tambem|ate|apos|conteudo|opcao|opcoes|selecao|configuracao|configuracoes|'
      r'conversao|reproducao|execucao|conexao|informacao|informacoes|pagina|paginas|capitulo|capitulos|'
      r'ultimo|ultima|titulo|indice|disponivel|possivel|invalido|numero|unico|licenca|biblioteca esta|esta vazi[oa]s?)\b',
      caseSensitive: false,
    );
    final offenders = <String>[];
    arb.forEach((key, value) {
      if (key.startsWith('@') || value is! String) return;
      final match = forbidden.firstMatch(value);
      if (match != null) offenders.add('$key: "${match.group(0)}" in "$value"');
    });
    expect(offenders, isEmpty);
  });
}

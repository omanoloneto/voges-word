# Voges Word

Editor de documentos leve, no espírito do Word, sem um milhão de opções. Abre e salva arquivos `.docx` de verdade e roda em macOS, Windows, Linux, Android, iOS e web (Flutter).

## O que faz

- Abre `.docx` e `.txt`; salva em `.docx` (padrão) ou `.txt`.
- Documento em páginas, como o Word: o texto passa para a página seguinte sozinho, parágrafos se dividem entre páginas (sem linha sozinha no pé ou no topo), títulos não ficam isolados no fim da página e tabelas quebram por linha. Também há o modo contínuo e zoom de 50% a 200%. Em telas estreitas o texto se ajusta à largura.
- Faixa de ferramentas em abas (Início, Inserir, Layout, Exibir e Tabela, que aparece ao editar uma célula), com galeria de estilos e cores rápidas.
- No computador, os botões da janela ficam dentro da faixa azul: à esquerda no Mac, à direita no Windows e, no Linux, do lado configurado no sistema (à direita se não houver configuração). Desfazer, refazer, copiar, recortar e colar ficam sempre do lado oposto.
- Fontes com busca: as instaladas no computador e 630 do Google Fonts, o terço mais popular entre as que escrevem português. As outras do Google aparecem quando você busca por elas; ao escolher uma, ela entra na sua lista.
- Uma fonte do Google é baixada na primeira vez que você a escolhe ou abre um documento que a usa. O arquivo é conferido pelo hash e fica guardado no aparelho.
- Calibri, Cambria, Arial, Times New Roman, Courier New, Georgia e Helvetica, quando não estão instaladas, aparecem com as equivalentes de mesma medida do Google Fonts (Carlito, Caladea, Arimo, Tinos, Cousine e Gelasio). Assim o texto quebra nas mesmas linhas que no Word.
- Layout da página: margens (Normal, ABNT, Estreita, Moderada, Larga), retrato ou paisagem e tamanho (A4, Carta, Ofício, A5), gravados no .docx.
- Menu Arquivo com documento novo a partir de modelos (em branco, espaçamento simples, trabalho escolar nas normas da ABNT, currículo) e arquivos abertos recentemente.
- Formatação do dia a dia: estilo (Normal, Título 1–3), fonte, tamanho, negrito, itálico, sublinhado, tachado, cor da fonte, realce, alinhamento, marcadores, numeração, recuo e espaçamento entre linhas.
- Inserir link, imagem, tabela (com linhas e colunas novas) e quebra de página.
- Tabelas editáveis célula por célula, inclusive com células mescladas.
- Localizar e substituir, contagem de palavras, desfazer/refazer.
- Avisa antes de fechar ou abrir outro arquivo com alterações não salvas.
- Pelo sistema: "Abrir com" no macOS (Finder) e no Android; no Windows e no Linux o caminho do arquivo pode ser passado na linha de comando.

## Fidelidade ao abrir e salvar

O Voges Word reescreve só o corpo do documento. Cabeçalhos, rodapés, estilos, tema, numeração, notas de rodapé, imagens e configurações de página continuam no arquivo como vieram. O que o editor mostra mas não edita (sumário, campos como número de página, equações, gráficos, caixas de texto, notas) fica protegido e volta para o arquivo exatamente igual.

Limitações conhecidas:

- A divisão em páginas é feita com as fontes disponíveis. Se o arquivo usa uma fonte que não está instalada e não tem equivalente no Google Fonts (como a Aptos), uma página pode terminar uma ou duas linhas antes ou depois do que no Word.
- No Android, no iOS e na web a lista traz só as fontes do Google: o Android não deixa usar as fontes do aparelho pelo nome.
- Para baixar fontes, o app acessa fonts.gstatic.com, do Google. Sem internet, a fonte aparece com outra até poder ser baixada.
- Cabeçalho e rodapé são mantidos, mas não aparecem nas páginas nem podem ser editados.
- Comentários não aparecem; alterações controladas são aceitas ao abrir.
- Recuo de primeira linha e espaçamento próprio de cada parágrafo são mantidos no arquivo, mas a tela usa o espaçamento do estilo Normal.
- Arquivos `.doc` antigos (Word 97–2003) não são suportados.

## Atalhos

| Ação | Atalho |
| --- | --- |
| Novo / Abrir / Salvar | Ctrl+N / Ctrl+O / Ctrl+S |
| Salvar como | Ctrl+Shift+S |
| Negrito / Itálico / Sublinhado | Ctrl+B / Ctrl+I / Ctrl+U |
| Alinhar esquerda / centro / direita / justificar | Ctrl+L / Ctrl+E / Ctrl+R / Ctrl+J |
| Link / Imagem | Ctrl+K / Ctrl+G |
| Localizar / Substituir | Ctrl+F / Ctrl+H |
| Quebra de linha no mesmo parágrafo | Shift+Enter |
| Quebra de página | Ctrl+Enter |
| Zoom | Ctrl+= / Ctrl+- / Ctrl+0 |

No macOS, use ⌘ no lugar de Ctrl.

## Desenvolvimento

Requer Flutter 3.41 ou mais novo.

```sh
flutter pub get
flutter run -d macos      # ou windows, linux, chrome, android
flutter test
```

Para testar com documentos reais sem colocá-los no repositório:

```sh
VW_SAMPLES=/pasta/com/docx flutter test test/docx_roundtrip_test.dart
```

Para gerar imagens da tela e conferir o visual (fontes do sistema, sem abrir o app):

```sh
VW_SCREENSHOTS=pasta-de-saida VW_SAMPLES=/pasta/com/docx flutter test test/screenshots_test.dart
```

A lista do Google Fonts (`assets/fonts/google_fonts.txt`) sai do código do pacote [google_fonts](https://pub.dev/packages/google_fonts) (licença BSD), com até quatro arquivos por família (normal, negrito, itálico e negrito itálico). Quais entram na lista padrão vem da popularidade publicada em fonts.google.com. Para atualizar:

```sh
dart run tool/google_fonts_catalog.dart ~/.pub-cache/hosted/pub.dev/google_fonts-<versão>/lib/src/google_fonts_parts
```

O editor de texto é o [flutter_quill](https://pub.dev/packages/flutter_quill) 11.5.0, copiado em `third_party/flutter_quill` (licença MIT) com a paginação acrescentada; as mudanças estão marcadas com `Voges Word:`.

## Estrutura

- `lib/docx/` — leitura e gravação de `.docx` (pacote zip, estilos, numeração, conversão para o modelo do editor e de volta).
- `lib/document/` — modelo do documento: formatos, aparência da página, tabelas e conteúdos protegidos.
- `lib/editor/` — tela, páginas, faixa de ferramentas, menu Arquivo, tabelas, busca e sessão (abrir, salvar, alterações).
- `lib/files/` — diálogos de arquivo, arquivos abertos pelo sistema e recentes.
- `lib/fonts/` — fontes instaladas, catálogo e download do Google Fonts.
- `tool/` — gerador da lista do Google Fonts.
- `third_party/flutter_quill/` — editor de texto com paginação.

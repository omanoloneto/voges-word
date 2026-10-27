# Voges Word

Editor de documentos leve, no espírito do Word, sem um milhão de opções. Abre e salva arquivos `.docx` de verdade e roda em macOS, Windows, Linux, Android, iOS e web (Flutter).

## O que faz

- Abre `.docx` e `.txt`; salva em `.docx` (padrão) ou `.txt`.
- Documento em páginas, como o Word: o texto passa para a página seguinte sozinho, parágrafos se dividem entre páginas (sem linha sozinha no pé ou no topo), títulos não ficam isolados no fim da página e tabelas quebram por linha. Também há o modo contínuo e zoom de 50% a 200%. Em telas estreitas o texto se ajusta à largura.
- Faixa de ferramentas em abas (Início, Inserir, Layout, Exibir e Tabela, que aparece ao editar uma célula), com galeria de estilos e cores rápidas.
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

- A divisão em páginas é feita com as fontes do seu computador; se o arquivo usa fontes que você não tem (Calibri, Aptos), uma página pode terminar uma ou duas linhas antes ou depois do que no Word.
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

O editor de texto é o [flutter_quill](https://pub.dev/packages/flutter_quill) 11.5.0, copiado em `third_party/flutter_quill` (licença MIT) com a paginação acrescentada; as mudanças estão marcadas com `Voges Word:`.

## Estrutura

- `lib/docx/` — leitura e gravação de `.docx` (pacote zip, estilos, numeração, conversão para o modelo do editor e de volta).
- `lib/document/` — modelo do documento: formatos, aparência da página, tabelas e conteúdos protegidos.
- `lib/editor/` — tela, páginas, faixa de ferramentas, menu Arquivo, tabelas, busca e sessão (abrir, salvar, alterações).
- `lib/files/` — diálogos de arquivo, arquivos abertos pelo sistema e recentes.
- `third_party/flutter_quill/` — editor de texto com paginação.

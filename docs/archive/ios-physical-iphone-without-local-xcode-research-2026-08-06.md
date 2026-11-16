# Executar no iPhone físico sem Xcode local — pesquisa

**Escopo:** iPhone 16e em iOS 27, Mac Intel em macOS Sonoma, com Xcode 15.4 incapaz de montar o suporte do dispositivo (`connected (no DDI)`). Pesquisa concluída em **2026-08-06**. Este documento não altera código nem configuração do app.

## Conclusão curta

**Use uma CI macOS remota com Xcode/SDK compatível com iOS 27 para arquivar, assinar e enviar ao App Store Connect; instale pelo TestFlight no iPhone.** É o caminho oficial mais apropriado para ciclos reais de QA, não requer Xcode, cabo, pareamento ou Developer Disk Image (DDI) no Mac local, suporta App Groups e share extension quando os entitlements/perfis são configurados corretamente, e elimina a incompatibilidade do Xcode 15.4.

O iOS instalado no iPhone não exige que o Mac local tenha o SDK/DDI correspondente para instalar uma build já distribuída. O DDI é parte do fluxo de desenvolvimento/depuração com Xcode; não é uma pré-condição do TestFlight.

> **Nota de versão:** "iOS 27" é tratado aqui como a versão que de fato está no aparelho. A CI deve selecionar a versão de Xcode que a Apple disponibiliza e aceita para esse SDK/destino no momento da build/upload. Não é seguro supor que Xcode 15.4 consiga fazê-lo.

## Comparativo de caminhos

| Caminho | Build | Assinatura/provisionamento | Instalação no iPhone | Xcode/DDI local? | Veredito |
|---|---|---|---|---|---|
| **TestFlight + CI remota** | `xcodebuild archive/export` em macOS remoto com Xcode atual; upload ao App Store Connect | Apple Developer Program; App ID explícito e capacidades; certificado/perfil de distribuição App Store Connect (ou assinatura gerida no serviço de CI) | TestFlight, convite/link para o Apple Account do testador | **Não.** Nem o Mac nem o iPhone precisam estar conectados ao Xcode local. | **Recomendado.** |
| **Ad hoc + CI remota** | Mesmo archive/export remoto, exportado como `.ipa` ad hoc | Apple Developer Program; App ID, certificado de distribuição, perfil ad hoc e UDID do iPhone previamente registrado | Entregar/instalar a IPA por mecanismo compatível, por exemplo Apple Configurator; Developer Mode é exigido para a IPA local | **Xcode não; DDI não.** Apple documenta expressamente ad hoc como execução sem Xcode. | Viável para um conjunto pequeno e fixo de aparelhos; mais operação e menos conveniente que TestFlight. |
| **Sideloading pessoal (Apple Account gratuito)** | O fluxo oficial de execução pessoal é build/assinatura de desenvolvimento pelo Xcode | Conta Apple permite teste no dispositivo, mas **não** dá distribuição, App Store Connect, ad hoc nem capacidades avançadas do programa | Fluxo oficial é “Run” por Xcode; instalações de IPA por ferramentas de terceiros não constituem fluxo Apple suportado | **Não atende** ao requisito sem Xcode local no caminho oficial. | **Não recomendado/não viável oficialmente** para este app, sobretudo com App Groups/share extension. |

## 1. TestFlight/App Store Connect com CI remota (recomendado)

### O que a CI precisa fazer

1. Rodar em um macOS remoto que tenha uma versão de Xcode atual, com SDK e cadeia de assinatura adequados ao destino iOS 27.
2. Resolver dependências, arquivar o esquema de distribuição e produzir uma build assinada para App Store Connect. Isso é trabalho da máquina remota; o Mac Sonoma Intel local só acompanha logs e usa o navegador.
3. Garantir que os identificadores e os perfis dentro da build correspondam aos do App Store Connect. A Apple informa que builds elegíveis ao TestFlight devem incluir os application identifiers nos provisioning profiles.
4. Fazer upload. A Apple aceita upload por **Xcode, Swift Playground, altool ou Transporter**; portanto uma CI remota pode enviar com Transporter/CLI e JWT do App Store Connect, sem Xcode instalado no Mac local. A própria Apple também lista Xcode Cloud como forma de criar e enviar builds.
5. Após processamento, atribuir a build ao grupo TestFlight. Testadores internos podem começar conforme as permissões; externos podem exigir Beta App Review. A build expira após 90 dias.

### Assinatura e conta

- É necessário estar no **Apple Developer Program** para distribuição/App Store Connect e capacidades avançadas. A comparação oficial da Apple marca App distribution, App Store Connect e ad hoc como benefícios do programa pago; uma Apple Account gratuita apenas permite desenvolvimento e teste no dispositivo.
- Use App ID **explícito**, não wildcard, para o app e IDs explícitos para extensões. Apple define App ID como o identificador incluído no provisioning profile e como a lista de permissões das capabilities.
- Proteja o certificado/chave de distribuição e os perfis no cofre de secrets da CI, ou use a gestão de assinatura que o serviço escolhido oferecer. Para upload automatizado, usar uma chave App Store Connect API/JWT de escopo mínimo, não uma senha pessoal.

### DDI, cabo e Developer Mode

- **DDI local: não.** O telefone instala a build pela infraestrutura de distribuição da Apple, não pela sessão de debug do Xcode 15.4.
- **Xcode local: não.** Não é necessário abrir o projeto, conectar o telefone ou pareá-lo localmente.
- **Developer Mode: não para TestFlight.** A documentação da Apple diz explicitamente que Developer Mode não afeta instalação normal como App Store ou participação em time TestFlight.

### Limites práticos

- Não oferece anexação de debugger local, logs ao vivo do Xcode nem LLDB no Mac local. Instrumentação de diagnóstico deve ser coletada pela própria app/serviço e pelos relatórios de crash/TestFlight.
- Primeiro envio externo pode aguardar Beta App Review; builds TestFlight têm validade máxima de 90 dias.

## 2. Ad hoc com CI remota

Este é o caminho oficial para instalar uma IPA em aparelhos registrados sem depender do Xcode local. A Apple declara: um perfil ad hoc permite executar o app em devices **sem precisar de Xcode**.

### Pré-requisitos e fluxo

1. Inscrever-se no Apple Developer Program.
2. Registrar o iPhone 16e pelo **UDID** no portal. A Apple informa que um device registrado é necessário para criar perfil development ou ad hoc.
3. Criar/usar App IDs explícitos, habilitar capabilities e registrar o grupo de app quando aplicável.
4. Criar certificado de distribuição e perfil **ad hoc** contendo todos os devices registrados e os App IDs/capabilities necessários.
5. Na CI macOS remota, arquivar e exportar a IPA ad hoc, assinando o app principal **e cada extensão embutida** com perfis compatíveis.
6. Transferir a IPA por canal controlado e instalá-la usando um mecanismo suportado. A documentação de Developer Mode cita explicitamente a instalação de um `.ipa` via **Apple Configurator** como caso de software assinado para desenvolvimento.

### DDI / Developer Mode / limitações

- **DDI local: não** para este fluxo de distribuição; não há deploy/depuração pelo Xcode local.
- **Xcode local: não**, mas haverá uma ferramenta de instalação no Mac (por exemplo, Apple Configurator) e conexão física/pareamento conforme a ferramenta.
- **Developer Mode: sim**, para instalação local de IPA. A Apple diz que ele é necessário para cenários como instalar uma `.ipa` com Apple Configurator; a pessoa deve confirmá-lo em Ajustes > Privacidade e Segurança, reiniciar e autenticar.
- O dispositivo deve continuar registrado e incluído no perfil. Cada nova IPA/alteração de perfil exige regenerar/redistribuir a IPA. Não há atualização automática, convite, feedback e crash metrics do TestFlight.
- Não use ad hoc para público amplo ou distribuição comercial. Ele é apropriado a teste/uso interno com dispositivos previamente autorizados.

## 3. “Sideloading” pessoal

### O que é oficialmente possível

Uma Apple Account gratuita permite aprender/desenvolver e testar apps em dispositivos. Porém a própria Apple separa isso de distribuição: para distribuir apps, é preciso aderir ao Apple Developer Program. A tabela oficial só atribui App distribution, App Store Connect e ad hoc ao programa pago.

O caminho Apple documentado para uma app assinada de desenvolvimento é executar via Xcode em dispositivo, e isso aciona Developer Mode. Logo, **não há um caminho oficial de sideload pessoal “sem Xcode local” que substitua TestFlight/ad hoc**.

### O que não recomendar

Ferramentas de terceiros que reassinam/instalam IPA podem mudar certificados, IDs, entitlements e ciclos de renovação. Elas não são um mecanismo Apple documentado para este propósito e, em especial, são inadequadas para confirmar o comportamento de uma share extension e de App Groups. Não as trate como evidência de que a IPA de produção/distribuição está corretamente assinada.

## App Groups + share extension: exigências em todos os caminhos viáveis

1. **Mesmo time:** App Groups permite que apps do mesmo desenvolvedor compartilhem containers; a documentação cita explicitamente compartilhamento entre uma app extension e sua host app.
2. **Registrar e associar o grupo:** registrar o identificador `group.<nome>` no portal e habilitar o grupo tanto no target da app host quanto no target da share extension. A Apple exige registrar grupos para apps iOS e informa que cada conta pode registrar até 1.000.
3. **IDs e capabilities por target:** app host e share extension são targets/bundles distintos. Cada um precisa de App ID explícito com a capability App Groups habilitada e de um perfil que autorize seu respectivo `application-identifier` e entitlement `com.apple.security.application-groups`.
4. **Assinatura da árvore inteira:** a CI deve assinar coerentemente o `.app` e o `.appex` embutido. Um perfil/certificado válido somente para a app host não basta para a extensão; uma inconsistência normalmente impede instalação/lançamento ou acesso ao container compartilhado.
5. **Distribuição:** TestFlight e ad hoc não restringem semanticamente App Groups ou share extension além dessas regras de entitlement, perfil e assinatura. A conta gratuita/personal team não é a escolha adequada porque App Groups é uma capability avançada associada à membership do programa.

## Recomendação operacional

1. **Adotar TestFlight + CI macOS remota agora.** Use um runner macOS com a versão atual de Xcode/SDK que suporte iOS 27 e configure archive + assinatura App Store Connect + upload automático a cada build de QA.
2. **Fazer um primeiro teste interno TestFlight** no iPhone 16e; ele é a prova de execução real sem DDI e sem Xcode local. Validar em particular a invocação da share extension e leitura/escrita no App Group.
3. Manter **ad hoc** apenas como plano B para instalar fora do TestFlight em um UDID específico, aceitando o custo de Developer Mode e gestão manual de IPA/perfis.
4. **Não investir em sideload pessoal** para este caso. Ele conflita com a exigência de não instalar Xcode local e não é um substituto oficial/sólido para capabilities avançadas.

## Fontes oficiais Apple

- [TestFlight overview — App Store Connect Help](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/) — distribuição beta, limites de testers, revisão externa e validade de 90 dias.
- [Upload builds — App Store Connect Help](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/) — upload por Xcode, Swift Playground, altool ou Transporter; API/JWT; Xcode Cloud.
- [Choosing a Membership — Apple Developer](https://developer.apple.com/support/compare-memberships/) — diferenças entre Apple Account gratuita e Apple Developer Program, inclusive distribuição, App Store Connect e ad hoc.
- [Create an ad hoc provisioning profile — Account Help](https://developer.apple.com/help/account/provisioning-profiles/create-an-ad-hoc-provisioning-profile/) — pré-requisitos e declaração expressa de execução sem Xcode.
- [Register a single device — Account Help](https://developer.apple.com/help/account/devices/register-a-single-device/) — UDID/device registrado para perfil development/ad hoc.
- [Register an App ID — Account Help](https://developer.apple.com/help/account/identifiers/register-an-app-id/) — App ID no provisioning profile e allowlist de capabilities.
- [Register an app group — Account Help](https://developer.apple.com/help/account/identifiers/register-an-app-group/) — registro e permissões do grupo.
- [Configuring app groups — Apple Developer Documentation](https://developer.apple.com/documentation/xcode/configuring-app-groups) — compartilhamento host app ↔ app extension, entitlement e grupos `group.*`.
- [Enabling Developer Mode on a device — Apple Developer Documentation](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device) — TestFlight não é afetado; Xcode/IPA via Apple Configurator exige Developer Mode.

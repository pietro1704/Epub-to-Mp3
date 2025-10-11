# 🤖 Bot de Telegram - Conversor de Ebooks

Bot intuitivo para conversão de EPUB/PDF em audiobooks MP3, acessível para usuários não-técnicos.

## 📋 Funcionalidades

- ✅ Envio de arquivos EPUB/PDF direto no chat
- ✅ Interface conversacional intuitiva com menus
- ✅ Suporte a todos os motores TTS (Edge, Coqui, Piper)
- ✅ Seleção de vozes PT-BR de alta qualidade
- ✅ Configuração de notas de rodapé (inline/fim/ignorar)
- ✅ Seleção de capítulos específicos
- ✅ Download automático dos MP3s gerados
- ✅ Cache inteligente para economizar processamento

## 🚀 Como Configurar

### 1. Criar Bot no Telegram

1. Abra o Telegram e procure por `@BotFather`
2. Envie o comando `/newbot`
3. Escolha um nome para seu bot (ex: "Meu Conversor de Ebooks")
4. Escolha um username (ex: "meu_ebook_bot")
5. Copie o **token** fornecido

### 2. Instalar Dependências

```bash
# Instalar dependências Python
pip install -r python_app/requirements.txt

# Verificar instalação
python -c "from telegram import Bot; print('✅ telegram-bot instalado')"
```

### 3. Configurar Token

Opção A - Variável de ambiente:
```bash
export TELEGRAM_BOT_TOKEN="seu_token_aqui"
```

Opção B - Arquivo .env:
```bash
# Copiar exemplo
cp .env.example .env

# Editar .env e adicionar seu token
nano .env
```

### 4. Iniciar Bot

```bash
# Modo simples
python python_app/telegram_bot.py

# Com log detalhado
python python_app/telegram_bot.py --verbose
```

## 📱 Como Usar

### Comandos Disponíveis

- `/start` - Iniciar conversa e enviar arquivo
- `/help` - Ajuda detalhada
- `/cancel` - Cancelar operação atual

### Fluxo de Uso

1. **Iniciar**: Envie `/start` no chat do bot
2. **Enviar arquivo**: Arraste seu EPUB/PDF para o chat
3. **Escolher motor**: Selecione Edge-TTS, Coqui ou Piper
4. **Escolher voz**: Selecione a voz desejada
5. **Configurar**:
   - Notas de rodapé: inline/fim/ignorar
   - Capítulos: todos, específicos ou intervalo
   - Cache: limpar ou manter
6. **Converter**: Confirme e aguarde
7. **Receber**: Downloads automáticos dos MP3s

## 🎙️ Motores de Voz

### Edge-TTS (Recomendado para iniciantes)
- **Vantagens**: Rápido, alta qualidade, não requer instalação extra
- **Desvantagens**: Requer internet
- **Vozes disponíveis**:
  - 🎤 Thalita (Feminina, multilíngue)
  - 👨 Antonio (Masculina)
  - 🌍 Guy (Inglês)

### Coqui TTS (Para melhor qualidade)
- **Vantagens**: IA avançada, funciona offline, clonagem de voz
- **Desvantagens**: Mais lento, requer mais recursos
- **Modelos**:
  - 🌟 XTTS v2 (melhor qualidade)
  - ⚡ VITS PT-BR (mais rápido)

### Piper (Para velocidade)
- **Vantagens**: Muito rápido, leve, offline
- **Desvantagens**: Qualidade média
- **Requer**: Modelos baixados em `python_app/models/`

## ⚙️ Opções Avançadas

### Notas de Rodapé

- **Inline**: Lê durante o texto
  ```
  "O Brasil foi descoberto em 1500 [nota: por Pedro Álvares Cabral]"
  ```

- **Fim do Capítulo**: Agrupa todas no final
  ```
  "O Brasil foi descoberto em 1500"
  ...
  [Fim do capítulo]
  "Nota 1: por Pedro Álvares Cabral"
  ```

- **Ignorar**: Não lê notas

### Seleção de Capítulos

Exemplos de entrada:
- `all` - Todos os capítulos
- `1,3,5` - Capítulos 1, 3 e 5
- `1-5` - Capítulos de 1 a 5
- `1,3-5,7` - Capítulos 1, 3 a 5, e 7

### Cache

O bot mantém cache de livros processados para:
- Trocar de voz sem reprocessar
- Retomar conversões interrompidas
- Economizar tempo e recursos

Use "Limpar cache" para:
- Forçar reprocessamento
- Liberar espaço em disco
- Corrigir problemas de conversão

## 🔧 Solução de Problemas

### Bot não responde
```bash
# Verificar se está rodando
ps aux | grep telegram_bot

# Ver logs
python python_app/telegram_bot.py --verbose
```

### Erro de token
```bash
# Verificar se token está configurado
echo $TELEGRAM_BOT_TOKEN

# Testar token
python -c "from telegram import Bot; Bot('seu_token').get_me()"
```

### Arquivo muito grande
- Limite do Telegram: 50MB por arquivo
- Solução: Converter capítulos específicos
- Ou: Comprimir com bitrate menor

### Sem modelos Piper
```bash
# Baixar modelo PT-BR recomendado
cd python_app/models
wget https://github.com/rhasspy/piper/releases/download/v1.2.0/pt_BR-faber-medium.onnx
wget https://github.com/rhasspy/piper/releases/download/v1.2.0/pt_BR-faber-medium.onnx.json
```

## 🌐 Deploy em Servidor

### Usando systemd (Linux)

1. Criar arquivo de serviço:
```bash
sudo nano /etc/systemd/system/ebook-bot.service
```

2. Conteúdo:
```ini
[Unit]
Description=Ebook Telegram Bot
After=network.target

[Service]
Type=simple
User=seu_usuario
WorkingDirectory=/caminho/para/Epub-to-Mp3
Environment="TELEGRAM_BOT_TOKEN=seu_token"
ExecStart=/usr/bin/python3 /caminho/para/Epub-to-Mp3/python_app/telegram_bot.py
Restart=always

[Install]
WantedBy=multi-user.target
```

3. Ativar:
```bash
sudo systemctl enable ebook-bot
sudo systemctl start ebook-bot
sudo systemctl status ebook-bot
```

### Usando Docker

```dockerfile
FROM python:3.11-slim

WORKDIR /app
COPY . .

RUN pip install -r python_app/requirements.txt
RUN apt-get update && apt-get install -y ffmpeg

ENV TELEGRAM_BOT_TOKEN=""

CMD ["python", "python_app/telegram_bot.py"]
```

```bash
docker build -t ebook-bot .
docker run -e TELEGRAM_BOT_TOKEN="seu_token" ebook-bot
```

### Usando VPS/Cloud

Recomendado:
- **DigitalOcean**: $5/mês (1GB RAM)
- **Hetzner**: €3/mês (2GB RAM)
- **AWS Lightsail**: $3.50/mês (512MB RAM)

Requisitos mínimos:
- 1GB RAM (2GB para Coqui)
- 10GB disco
- 1 CPU core

## 📊 Estatísticas de Uso

O bot registra:
- Número de conversões
- Engines mais usados
- Tempo médio de processamento
- Erros e falhas

Logs em: `telegram_bot.log`

## 🆘 Suporte

- Issues: https://github.com/seu-repo/issues
- Email: seu@email.com
- Telegram: @seu_username

## 📝 Licença

Mesma licença do projeto principal.

---

**Desenvolvido com ❤️ para democratizar o acesso a audiobooks**

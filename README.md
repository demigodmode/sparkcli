# sparkcli

vLLM wrapper for DGX Spark. Gives you Ollama-style model management without the Ollama runtime.

```
sparkcli pull Qwen/Qwen3-32B-FP8
sparkcli run  Qwen/Qwen3-32B-FP8
sparkcli ls
sparkcli stop
```

Ollama runs on Spark but leaves a lot of the hardware on the table (GGUF only, no FP4 tensor cores, no continuous batching). vLLM uses the hardware properly but gives you nothing for model management. sparkcli fills that part: pull models, switch between them, check what's running, without touching Docker flags each time.

The API is OpenAI-compatible (it's just vLLM), so anything pointed at OpenAI works against it.

## Install

```bash
git clone https://github.com/demigodmode/sparkcli
cd sparkcli
bash install.sh
```

Copy the config template and adjust for your setup:

```bash
cp config.conf.example ~/.sparkcli/config.conf
```

Run `sparkcli doctor` before your first pull to catch any missing pieces.

## Commands

```
sparkcli pull <model>     Download a model from HuggingFace
sparkcli run  <model>     Serve it with vLLM
sparkcli rm   <model>     Remove it from disk
sparkcli ls               List models, what's downloaded, what's running
sparkcli status           Health check on the running model
sparkcli stop             Stop vLLM
sparkcli logs [-f]        Container logs
sparkcli info  <model>    Flags, context length, disk usage
sparkcli update           Rebuild the vLLM Docker image
sparkcli doctor           Pre-flight checks
sparkcli help             Show this command list
```

## Models

Only models listed in `models.conf` are supported. Each entry includes the correct vLLM flags for that model (tool call parsers, reasoning parsers, context length). Getting these wrong either breaks the model or silently degrades output quality, so arbitrary model IDs aren't accepted.

Currently Qwen3 variants tested on DGX Spark. More coming.

To add a model, open an issue using the **New Model** template. If you've tested it yourself, include the curl output so it can be merged faster.

## Requirements

- NVIDIA GPU (tested on DGX Spark GB10)
- Docker with NVIDIA runtime
- A vLLM Docker image (NGC or custom)
- HuggingFace account (token needed for gated models)

## Contributing

Personal tool that I'm sharing in case it's useful. Contributions welcome, especially model submissions and testing on non-Spark NVIDIA hardware.

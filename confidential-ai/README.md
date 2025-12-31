# Confidential AI Examples

Run AI workloads with hardware-enforced privacy. Your prompts, model weights, and computations stay encrypted in memory.

| Example | Description | Status |
|---------|-------------|--------|
| [inference](./inference) | Private LLM with response signing | Ready to deploy |
| [training](./training) | Fine-tuning on sensitive data | Requires local build |
| [agents](./agents) | AI agent with TEE-derived keys | Requires local build |

Start with inference—it deploys in one command and shows the full attestation flow.

```bash
cd inference
phala auth login
phala deploy -n my-llm -c docker-compose.yaml \
  --instance-type h200.small \
  -e TOKEN=your-secret-token
```

First deployment takes 10-15 minutes (large images + model loading). Check progress with `phala cvms serial-logs <app_id> --tail 100`.

See the [Confidential AI Guide](https://github.com/Dstack-TEE/dstack/blob/master/docs/confidential-ai.md) for how the security model works.

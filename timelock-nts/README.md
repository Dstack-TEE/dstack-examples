Timelock example using cloudflare's time service
#

Cloudflare provides a secure time oracle service.
Roughly it lets you connect over TLS and it gives you the current time.

Read more about this service here:
https://blog.cloudflare.com/secure-time/
https://developers.cloudflare.com/time-services/nts/

So, this example functions pretty simply:
- first it generates a public key
- it also outputs a remote attestation, where the `report_data` includes the public key and the release time (5 minutes in the future)
- after the release time is reached according to the oralce, it outputs the private key
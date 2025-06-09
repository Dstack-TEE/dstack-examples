# ConfigID-based Dstack Remote Attestation Verification

Dstack v0.5.1 introduced [compose_hash in mr_config_id](https://github.com/Dstack-TEE/dstack/pull/190), which simplifies the verification process compared to the RTMR3-based verification. The verification doesn't need to replay the RTMRs, and only needs to compare the RTMRs and mr_config_id to known good values.

## Steps

This guide walks you through the process of deploying a Dstack application and verifying its attestation using ConfigID-based verification.

### 1. Download Required Materials

```bash
./attest.sh download
```

**Explanation:** This step downloads all necessary tools and images required for the verification process:
- dcap-qvl tool for verifying Intel TDX quotes
- dstack-mr tool for calculating expected measurement values
- Dstack VM image that will be used for deployment

The downloaded files are stored in the `work/bin` and `work/images` directories.

### 2. Prepare Application Composition

```bash
./attest.sh compose
```

**Explanation:** This step generates an `app-compose.json` file based on the `docker-compose.yaml`. The app-compose.json file defines what code to run in the App and the configuration of the App. The script also calculates a compose hash, which is a SHA-256 hash of the app-compose.json file. This hash is crucial for the attestation verification process as it's used to create the mr_config_id.

### 3. Calculate Known Good Measurement Registers

```bash
./attest.sh calc-mrs
```

**Explanation:** Before deploying the application, this step calculates the expected "known good" measurement register values that should be present in a legitimate, unmodified deployment. It uses the dstack-mr tool to:
- Calculate the mr_config_id by taking the compose hash and padding it to 96 characters
- Generate expected values for RTMR[0-2] based on the VM image metadata and configuration
- Save these values to `known_good_mrs.json` for later comparison

### 4. Deploy the Application

```bash
./attest.sh deploy
```

**Explanation:** This step deploys the application to the Dstack environment:
- Uploads the app-compose.json to the dstack-vmm
- Creates a VM with the specified configuration
- Waits for the VM to boot and initialize
- Saves the instance ID for future reference

### 5. Verify Attestation

```bash
./attest.sh verify
```

**Explanation:** The final step verifies that the deployed application is running in a genuine Intel TDX environment with the expected configuration:
- Requests a quote from the application's `/quote.json` endpoint
- Verifies the quote using the dcap-qvl tool
- Compares the measurement registers in the quote with the known good values calculated earlier:
  - mr_config_id (contains the app-compose.json hash)
  - mr_td (TD measurement register)
  - rt_mr0, rt_mr1, rt_mr2 (runtime measurement registers)
- Displays the report data, which can contain application-specific attestation information

The verification process confirms that the application is running in a genuine TDX environment with the expected configuration and has not been tampered with.


## Full log

```bash
$ ./attest.sh download
Downloading materials required for verification...
Downloading DCAP QVL tool from https://github.com/Phala-Network/dcap-qvl/releases/download/v0.2.4/dcap-qvl-linux-amd64
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
  0     0    0     0    0     0      0      0 --:--:-- --:--:-- --:--:--     0
100 7144k  100 7144k    0     0  11.8M      0 --:--:-- --:--:-- --:--:-- 11.8M
Downloading Dstack MR tool from https://github.com/kvinwang/dstack-mr/releases/download/v0.5.0/dstack-mr-linux-amd64
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
  0     0    0     0    0     0      0      0 --:--:-- --:--:-- --:--:--     0
100 6603k  100 6603k    0     0  11.6M      0 --:--:-- --:--:-- --:--:--  104M
Downloading Dstack image...
Downloading image from https://github.com/Dstack-TEE/meta-dstack/releases/download/v0.5.1/dstack-0.5.1.tar.gz
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
  0     0    0     0    0     0      0      0 --:--:-- --:--:-- --:--:--     0
100  161M  100  161M    0     0  76.3M      0  0:00:02  0:00:02 --:--:-- 98.5M
Extracting image...
Image extracted successfully
Downloads completed successfully
```


```bash
$ ./attest.sh compose
Preparing app-compose.json for deployment...
Generating app-compose.json
app-compose.json has been prepared and is ready for deployment
Compose hash: eaae2351f15ecb6db16135b31039afa2a8b023e287c28200c44aeae5f0c206bd
```

```bash
$ ./attest.sh calc-mrs
Calculating known good MRs before deployment...
Using mr_config_id: eaae2351f15ecb6db16135b31039afa2a8b023e287c28200c44aeae5f0c206bd00000000000000000000000000000000
Running dstack-mr to calculate MRs...
MRs calculation completed. Results saved to known_good_mrs.json
```

```bash
$ ./attest.sh deploy
Deploying app...
Deploying app...
✅ App deployed successfully!
VM ID: 5ba3bcd0-7344-4450-b919-e86e52dd3b6c
Waiting for the app to start...
Boot progress: booting
Boot progress: booting
Boot progress: booting
Boot progress: booting
Boot progress: initializing data disk
Boot progress: initializing data disk
Boot progress: initializing data disk
✅ App started successfully!
Instance ID: 41c97635037ba6e5ac6752be10ed1036bb4797a7
```

```bash
$ ./attest.sh verify
Requesting quote from the app and verifying attestation...
Requesting quote from /quote
✅ Quote downloaded successfully!
Verifying attestation using DCAP QVL tool
Getting collateral from PCS...
Quote verified
✅ Attestation verification successful!
Comparing RTMRs with known good values...
Using TD10 report for verification
✅ mr_config_id matches known good value
✅ mr_td matches known good value
✅ rt_mr0 matches known good value
✅ rt_mr1 matches known good value
✅ rt_mr2 matches known good value
Report data:
12340000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
```

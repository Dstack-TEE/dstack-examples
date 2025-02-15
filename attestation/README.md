# Dstack Remote Attestation Example

This example illustrates the remote attestation process for every component of the Dstack Applications. It encompasses everything from the CPU microcode to the TDVF, VM configuration, kernel, kernel parameters and application code. For further details, please refer to our [attestation guide](https://github.com/Dstack-TEE/dstack/blob/6b77340cf530b4532c5815039a74bb3a60302378/attestation.md).

## Overview

The `verify.py` script demonstrates how to:
- Verify TDX quotes using Intel's DCAP 
- Parse and validate event logs
- Replay and verify Runtime Measurement Registers (RTMRs)
- Validate application integrity through compose hash verification

## Prerequisites

Before running the example, ensure you have the following installed:

1. **Python 3.10+**
   - Required for executing `verify.py`

2. **Dstack OS Image**
   - Either build from source or download from [Dstack Releases](https://github.com/Dstack-TEE/dstack/releases/tag/dev-v0.4.0.0)

3. **dcap-qvl**
   - A TDX/SGX quote verification tool from Phala
   - Install with: `cargo install dcap-qvl-cli`

4. **dstack-mr**
   - A tool to calculate expected measurement values for Dstack Base Images
   - Install with: `go install github.com/kvinwang/dstack-mr@latest`

## Setup

1. **Generate the Application Report:**
   - Run your Dstack application to produce a `report.json` file containing the attestation data

2. **Prepare the Compose File:**
   - Create and properly configure the `app-compose.json` file to match your application's settings

## Run the Example

Run the verification process simply by executing:
```bash
python verify.py
```
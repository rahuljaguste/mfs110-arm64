# Licensing and third-party notices

This repository contains original work plus a third-party binary.
**Read this before redistributing anything here.**

## Licensing at a glance

| Component | License | Our work? |
|---|---|---|
| `Setup-MFS110.bat` - installer | MIT | yes |
| `Test-MFS110.bat` - capture check | MIT | yes |
| `cyusb3.sys` `.inf` `.cat` | **Cypress/Infineon EULA** | **no** - see below |
| Cypress EZ-USB FX3 SDK | Cypress/Infineon EULA | **no** |
| Mantra MFS110 RD Service | Mantra's terms | **no** |

Full EULA text: [`licenses/cypress-ez-usb-fx3-sdk-EULA.txt`](licenses/cypress-ez-usb-fx3-sdk-EULA.txt).

## The driver binaries

The compiled ARM64 driver (`cyusb3.sys`, `cyusb3.inf`, `cyusb3.cat`) is a
**modified Cypress binary**, derived from Cypress/Infineon's `CyUsb3.sys`
under their EULA. It is not original work and is not covered by this
repository's MIT licence.

### Two conditions on redistribution

1. **"only when installed on a device that includes the Cypress hardware
   product that the Driver is intended to enable"** - the MFS110. The driver
   is useless without one, but a public download is not gated on ownership.
2. **Your own EULA must cover distribution**, containing at minimum a
   liability limitation and a prohibition on reverse engineering.

If you redistribute these binaries, you take on both.

### Test-signed, not WHQL-signed

They load only with **Secure Boot off** and **test-signing enabled**.
Obtaining a proper signature would require attestation signing through
Microsoft, which is not available for code you do not own.

## What the Cypress EULA permits

Quoting §2(c), which is why the project itself is legitimate:

> (i) if provided in Source Code form, to copy, modify, and compile the Driver
> Source Code to create one or more Drivers to enable the use of a Cypress
> hardware product on a particular host operating system, and (ii) to
> distribute the Driver, in binary code form only, only when installed on a
> device that includes the Cypress hardware product that the Driver is intended
> to enable

**Modifying for ARM64 is expressly allowed**, and distributing the result is
allowed on machines containing the hardware. That is what the installer script
does.

Also note: *"to freely distribute any inf File"*; the `.inf` carries no
restriction, unlike the `.sys` and `.cat`.

Export control obligations also apply (§7).

## Deliberately not in this repository

### Cypress driver source code

Every file in `CyUSB3_Source` carries:

```
Copyright Cypress Semiconductor Corporation, 2009-2012, All Rights Reserved
UNPUBLISHED, LICENSED SOFTWARE.
CONFIDENTIAL AND PROPRIETARY INFORMATION WHICH IS THE PROPERTY OF CYPRESS.
```

The EULA (§4) requires: *"You agree to keep the Source Code confidential."*

**Obtain it yourself** from Infineon's EZ-USB FX3 SDK. The transformation
scripts that add ARM64 support are our original work and carry no Cypress code,
but they are not distributed here. The binaries are ready to install as-is.
Rebuild instructions are available on request.

### Mantra's RD Service files

`MantraMFS110AVDMHost.exe` and its dependencies are Mantra Softech's software.
The Cypress EULA does not cover them, and we have no right to redistribute
them. Obtain them from Mantra.

## Commercial use

The Cypress EULA draws no distinction between commercial and non-commercial
use: no royalty, fee, or revenue restriction.

Structural limits remain:

- **You cannot sell the driver as a standalone product**; distribution
  requires a device containing the Cypress hardware.
- **Mantra's terms are a separate question**, not covered by the Cypress EULA.
  If you commercially supply MFS110 hardware, that is Mantra's agreement to
  check.
- **The RD Service is not yours to license.**

## Not legal advice

A reading of the license texts, not legal advice. The Cypress EULA is governed
by California law with venue in Santa Clara County (§12). For commercial
distribution, get a professional review, particularly of the Mantra side,
which is outside anything covered here.

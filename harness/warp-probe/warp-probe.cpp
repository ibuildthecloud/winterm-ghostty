// WARP / D3D11 device probe.
//
// Answers the Phase 1 escalation trigger from PLAN.md:
//   "WARP device creation fails on this machine (invalidates the ADR 0002
//    fallback story)."
//
// ADR 0002's degradation ladder is: hardware D3D11 -> WARP (same code path,
// covers RDP/driverless) -> device-removed rebuild -> engine-init failure.
// Step 2 is the one that has never been exercised here, so this probe creates
// a device each way and reports what the renderer would actually get.

#include <windows.h>
#include <d3d11.h>
#include <dxgi1_6.h>
#include <stdio.h>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")

static const char* featureLevelName(D3D_FEATURE_LEVEL fl) {
    switch (fl) {
        case D3D_FEATURE_LEVEL_12_2: return "12_2";
        case D3D_FEATURE_LEVEL_12_1: return "12_1";
        case D3D_FEATURE_LEVEL_12_0: return "12_0";
        case D3D_FEATURE_LEVEL_11_1: return "11_1";
        case D3D_FEATURE_LEVEL_11_0: return "11_0";
        case D3D_FEATURE_LEVEL_10_1: return "10_1";
        case D3D_FEATURE_LEVEL_10_0: return "10_0";
        default: return "<9.x or unknown>";
    }
}

// ghostty's renderer targets 11_0; anything below is a hard fail for us.
static const D3D_FEATURE_LEVEL kLevels[] = {
    D3D_FEATURE_LEVEL_11_1,
    D3D_FEATURE_LEVEL_11_0,
};

static int probeDevice(const char* label, D3D_DRIVER_TYPE type, IDXGIAdapter* adapter) {
    ID3D11Device* dev = nullptr;
    ID3D11DeviceContext* ctx = nullptr;
    D3D_FEATURE_LEVEL got = (D3D_FEATURE_LEVEL)0;

    // BGRA_SUPPORT is required for D2D/DComp interop, which the composition
    // surface path in Phase 2 depends on.
    UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;

    HRESULT hr = D3D11CreateDevice(
        adapter,
        type,
        nullptr,
        flags,
        kLevels,
        ARRAYSIZE(kLevels),
        D3D11_SDK_VERSION,
        &dev,
        &got,
        &ctx);

    if (FAILED(hr)) {
        printf("  %-22s FAILED  hr=0x%08lX\n", label, (unsigned long)hr);
        return 1;
    }

    printf("  %-22s OK      feature level %s\n", label, featureLevelName(got));

    // What is this device actually running on?
    IDXGIDevice* dxgiDev = nullptr;
    if (SUCCEEDED(dev->QueryInterface(__uuidof(IDXGIDevice), (void**)&dxgiDev))) {
        IDXGIAdapter* a = nullptr;
        if (SUCCEEDED(dxgiDev->GetAdapter(&a))) {
            DXGI_ADAPTER_DESC d = {};
            if (SUCCEEDED(a->GetDesc(&d))) {
                printf("  %-22s adapter: %ls (vendor 0x%04X device 0x%04X)\n",
                       "", d.Description, d.VendorId, d.DeviceId);
            }
            a->Release();
        }
        dxgiDev->Release();
    }

    // Threading model: ADR 0002 keeps ghostty's renderer thread and relies on
    // D3D11 being free-threaded. Verify the driver agrees.
    D3D11_FEATURE_DATA_THREADING th = {};
    if (SUCCEEDED(dev->CheckFeatureSupport(D3D11_FEATURE_THREADING, &th, sizeof(th)))) {
        printf("  %-22s threading: concurrent-creates=%d command-lists=%d\n",
               "", (int)th.DriverConcurrentCreates, (int)th.DriverCommandLists);
    }

    if (ctx) ctx->Release();
    dev->Release();
    return 0;
}

int main() {
    int failures = 0;

    printf("== DXGI adapters ==\n");
    IDXGIFactory1* factory1 = nullptr;
    if (SUCCEEDED(CreateDXGIFactory1(__uuidof(IDXGIFactory1), (void**)&factory1))) {
        IDXGIAdapter1* a = nullptr;
        for (UINT i = 0; factory1->EnumAdapters1(i, &a) != DXGI_ERROR_NOT_FOUND; ++i) {
            DXGI_ADAPTER_DESC1 d = {};
            if (SUCCEEDED(a->GetDesc1(&d))) {
                printf("  [%u] %ls%s  vram=%llu MB\n",
                       i, d.Description,
                       (d.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) ? "  (SOFTWARE)" : "",
                       (unsigned long long)(d.DedicatedVideoMemory / (1024 * 1024)));
            }
            a->Release();
        }
        factory1->Release();
    } else {
        printf("  CreateDXGIFactory1 FAILED\n");
        failures++;
    }

    printf("\n== D3D11 device creation (ADR 0002 degradation ladder) ==\n");
    failures += probeDevice("1. HARDWARE", D3D_DRIVER_TYPE_HARDWARE, nullptr);
    failures += probeDevice("2. WARP", D3D_DRIVER_TYPE_WARP, nullptr);

    // The renderer may prefer selecting the WARP *adapter* explicitly rather
    // than passing DRIVER_TYPE_WARP; both should work.
    printf("\n== WARP via explicit adapter (IDXGIFactory4::EnumWarpAdapter) ==\n");
    IDXGIFactory4* factory4 = nullptr;
    if (SUCCEEDED(CreateDXGIFactory1(__uuidof(IDXGIFactory4), (void**)&factory4))) {
        IDXGIAdapter* warp = nullptr;
        if (SUCCEEDED(factory4->EnumWarpAdapter(__uuidof(IDXGIAdapter), (void**)&warp))) {
            failures += probeDevice("3. WARP adapter", D3D_DRIVER_TYPE_UNKNOWN, warp);
            warp->Release();
        } else {
            printf("  EnumWarpAdapter FAILED\n");
            failures++;
        }
        factory4->Release();
    } else {
        printf("  IDXGIFactory4 unavailable\n");
        failures++;
    }

    // Cheap Phase 2 look-ahead: the composition path needs these two exports.
    printf("\n== Composition prerequisites (Phase 2 look-ahead) ==\n");
    HMODULE dcomp = LoadLibraryW(L"dcomp.dll");
    if (dcomp) {
        printf("  dcomp.dll                        loaded\n");
        printf("  DCompositionCreateSurfaceHandle  %s\n",
               GetProcAddress(dcomp, "DCompositionCreateSurfaceHandle") ? "present" : "MISSING");
        FreeLibrary(dcomp);
    } else {
        printf("  dcomp.dll                        MISSING\n");
    }

    printf("\n== RESULT: %s (%d failure%s) ==\n",
           failures == 0 ? "ALL PASS" : "FAILURES PRESENT",
           failures, failures == 1 ? "" : "s");
    return failures;
}

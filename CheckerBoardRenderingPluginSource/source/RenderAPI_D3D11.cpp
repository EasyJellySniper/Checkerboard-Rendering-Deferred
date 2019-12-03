#include "RenderAPI.h"
#include "PlatformBase.h"

// Direct3D 11 implementation of RenderAPI.

#if SUPPORT_D3D11

#include <assert.h>
#include <d3d11.h>
#include "Unity/IUnityGraphicsD3D11.h"
#include <wrl.h>
using namespace Microsoft::WRL;

class RenderAPI_D3D11 : public RenderAPI
{
public:
	RenderAPI_D3D11();
	virtual ~RenderAPI_D3D11() { }

	virtual void ProcessDeviceEvent(UnityGfxDeviceEventType type, IUnityInterfaces* interfaces);
	virtual bool CacheNativeGBuffer(void *_src, int _frame, int _gBufferId);
	virtual bool CacheNativeDepth(void *_src, int _frame);
	virtual void ReleaseNativeCBR();
	virtual void SetCbrGBuffer();
	virtual void RestoreUnityGBuffer();

private:
	bool CreateRtv(ID3D11Texture2D *_src, ComPtr<ID3D11RenderTargetView> &_dst);
	bool CreateDsv(ID3D11Texture2D *_src, ComPtr<ID3D11DepthStencilView> &_dst);
	DXGI_FORMAT FindFormatFromTypeless(DXGI_FORMAT _typeLessformat);
	static const int NumOfGBuffer = 5;
	int renderFrame = 0;

	ID3D11Device* m_Device;

	// raw cache
	ID3D11Texture2D *cbrGBuffer0[NumOfGBuffer];
	ID3D11Texture2D *cbrGBuffer1[NumOfGBuffer];
	ID3D11Texture2D *cbrDepth0;
	ID3D11Texture2D *cbrDepth1;

	// generated interfaces
	ComPtr<ID3D11RenderTargetView> cbrRtv0[NumOfGBuffer];
	ComPtr<ID3D11RenderTargetView> cbrRtv1[NumOfGBuffer];
	ComPtr<ID3D11DepthStencilView> cbrDsv0;
	ComPtr<ID3D11DepthStencilView> cbrDsv1;

	ComPtr<ID3D11RenderTargetView> unityGBuffer[NumOfGBuffer];
	ComPtr<ID3D11DepthStencilView> unityDepth;
};


RenderAPI* CreateRenderAPI_D3D11()
{
	return new RenderAPI_D3D11();
}

RenderAPI_D3D11::RenderAPI_D3D11()
{
	renderFrame = 0;
}

void RenderAPI_D3D11::ProcessDeviceEvent(UnityGfxDeviceEventType type, IUnityInterfaces* interfaces)
{
	switch (type)
	{
	case kUnityGfxDeviceEventInitialize:
	{
		IUnityGraphicsD3D11* d3d = interfaces->Get<IUnityGraphicsD3D11>();
		m_Device = d3d->GetDevice();
		break;
	}
	case kUnityGfxDeviceEventShutdown:
		break;
	}
}

bool RenderAPI_D3D11::CacheNativeGBuffer(void * _src, int _frame, int _gBufferId)
{
	if (_frame == 0)
	{
		cbrGBuffer0[_gBufferId] = (ID3D11Texture2D*)_src;
		return CreateRtv(cbrGBuffer0[_gBufferId], cbrRtv0[_gBufferId]);
	}
	else
	{
		cbrGBuffer1[_gBufferId] = (ID3D11Texture2D*)_src;
		return CreateRtv(cbrGBuffer1[_gBufferId], cbrRtv1[_gBufferId]);
	}

	return false;
}

bool RenderAPI_D3D11::CacheNativeDepth(void * _src, int _frame)
{
	if (_frame == 0)
	{
		cbrDepth0 = (ID3D11Texture2D*)_src;
		return CreateDsv(cbrDepth0, cbrDsv0);
	}
	else
	{
		cbrDepth1 = (ID3D11Texture2D*)_src;
		return CreateDsv(cbrDepth1, cbrDsv1);
	}

	return false;
}

void RenderAPI_D3D11::ReleaseNativeCBR()
{
	for (int i = 0; i < NumOfGBuffer; i++)
	{
		cbrRtv0[i].Reset();
		cbrRtv1[i].Reset();
	}

	cbrDsv0.Reset();
	cbrDsv1.Reset();

	unityDepth.Reset();
	for (int i = 0; i < NumOfGBuffer; i++)
	{
		unityGBuffer[i].Reset();
	}

	renderFrame = 0;
}

void RenderAPI_D3D11::SetCbrGBuffer()
{
	ID3D11DeviceContext *ic;
	m_Device->GetImmediateContext(&ic);

	if (ic == nullptr)
	{
		return;
	}

	// set CBR GBuffer
	FLOAT clearColor[4] = { 0,0,0,-1 };
	FLOAT maskColor[4] = { 1,1,1,1 };

	// cache unity's gbuffer
	unityDepth.Reset();
	for (int i = 0; i < NumOfGBuffer; i++)
	{
		unityGBuffer[i].Reset();
	}
	ic->OMGetRenderTargets(NumOfGBuffer, unityGBuffer->GetAddressOf(), unityDepth.GetAddressOf());

	if (renderFrame == 0)
	{
		for (int i = 0; i < NumOfGBuffer; i++)
		{
			ic->ClearRenderTargetView(cbrRtv0[i].Get(), (i != 4) ? clearColor : maskColor);
		}
		ic->ClearDepthStencilView(cbrDsv0.Get(), D3D11_CLEAR_DEPTH | D3D11_CLEAR_STENCIL, 0.0f, 0);
		ic->OMSetRenderTargets(NumOfGBuffer, cbrRtv0->GetAddressOf(), cbrDsv0.Get());
	}
	else
	{
		// shift view port a little bit
		D3D11_VIEWPORT cbrViewPort;
		UINT numVP = 1;
		ic->RSGetViewports(&numVP, &cbrViewPort);

		cbrViewPort.TopLeftX = 0.5f;
		ic->RSSetViewports(1, &cbrViewPort);

		for (int i = 0; i < NumOfGBuffer; i++)
		{
			ic->ClearRenderTargetView(cbrRtv1[i].Get(), (i != 4) ? clearColor : maskColor);
		}
		ic->ClearDepthStencilView(cbrDsv1.Get(), D3D11_CLEAR_DEPTH | D3D10_CLEAR_STENCIL, 0.0f, 0);
		ic->OMSetRenderTargets(NumOfGBuffer, cbrRtv1->GetAddressOf(), cbrDsv1.Get());
	}

	renderFrame = (renderFrame + 1) % 2;

	ic->Release();
}

void RenderAPI_D3D11::RestoreUnityGBuffer()
{
	ID3D11DeviceContext *ic;
	m_Device->GetImmediateContext(&ic);

	if (ic == nullptr)
	{
		return;
	}

	ic->OMSetRenderTargets(NumOfGBuffer, unityGBuffer->GetAddressOf(), unityDepth.Get());

	ic->Release();
}

#endif // #if SUPPORT_D3D11


bool RenderAPI_D3D11::CreateRtv(ID3D11Texture2D *_src, ComPtr<ID3D11RenderTargetView> &_dst)
{
	D3D11_TEXTURE2D_DESC desc;
	_src->GetDesc(&desc);

	D3D11_RENDER_TARGET_VIEW_DESC rtvDesc;
	ZeroMemory(&rtvDesc, sizeof(rtvDesc));
	rtvDesc.ViewDimension = D3D11_RTV_DIMENSION_TEXTURE2DMS;
	rtvDesc.Format = FindFormatFromTypeless(desc.Format);
	
	HRESULT hr = m_Device->CreateRenderTargetView(_src, &rtvDesc, _dst.GetAddressOf());
	
	return SUCCEEDED(hr);
}

bool RenderAPI_D3D11::CreateDsv(ID3D11Texture2D * _src, ComPtr<ID3D11DepthStencilView>& _dst)
{
	D3D11_TEXTURE2D_DESC desc;
	_src->GetDesc(&desc);

	D3D11_DEPTH_STENCIL_VIEW_DESC dsvDesc;
	ZeroMemory(&dsvDesc, sizeof(dsvDesc));
	dsvDesc.ViewDimension = D3D11_DSV_DIMENSION_TEXTURE2DMS;
	dsvDesc.Format = FindFormatFromTypeless(desc.Format);

	HRESULT hr = m_Device->CreateDepthStencilView(_src, &dsvDesc, _dst.GetAddressOf());

	return SUCCEEDED(hr);
}

DXGI_FORMAT RenderAPI_D3D11::FindFormatFromTypeless(DXGI_FORMAT _typeLessformat)
{
	switch (_typeLessformat)
	{
		case DXGI_FORMAT_R8G8B8A8_TYPELESS:
		{
			return DXGI_FORMAT_R8G8B8A8_UNORM;
		}
		case DXGI_FORMAT_R10G10B10A2_TYPELESS:
		{
			return DXGI_FORMAT_R10G10B10A2_UNORM;
		}
		case DXGI_FORMAT_R32G8X24_TYPELESS:
		{
			return DXGI_FORMAT_D32_FLOAT_S8X24_UINT;
		}
		case DXGI_FORMAT_R16G16B16A16_TYPELESS:
		{
			return DXGI_FORMAT_R16G16B16A16_FLOAT;
		}
		default:
		{
			break;
		}
	}

	return _typeLessformat;
}

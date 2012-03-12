package h3d;
import h3d.mat.Data;

class Engine {

	var s3d : flash.display.Stage3D;
	var ctx : flash.display3D.Context3D;
	
	public var camera : h3d.Camera;
	public var mem(default,null) : h3d.impl.MemoryManager;
	
	public var hardware(default, null) : Bool;
	public var width(default, null) : Int;
	public var height(default, null) : Int;
	public var debug(default, setDebug) : Bool;
	
	public var drawTriangles(default, null) : Int;
	public var drawCalls(default, null) : Int;
	
	public var backgroundColor : Int;
	
	var curMat : h3d.mat.Material;
	var curShader : Shader.ShaderData;
	var curBuffer : h3d.impl.MemoryManager.BigBuffer;
	var curAttributes : Int;
	var curTextures : Array<h3d.mat.Texture>;
	
	public function new( width = 0, height = 0, hardware = true ) {
		var stage = flash.Lib.current.stage;
		if( width == 0 ) width = stage.stageWidth;
		if( height == 0 ) height = stage.stageHeight;
		this.width = width;
		this.height = height;
		this.hardware = hardware;
		s3d = stage.stage3Ds[0];
		camera = new Camera();
	}
	
	public function init() {
		s3d.addEventListener(flash.events.Event.CONTEXT3D_CREATE, function(_) onCreate());
		s3d.requestContext3D( hardware ? "auto" : "software" );
	}
	
	public function driverName() {
		return ctx == null ? "None" : ctx.driverInfo.split(" ")[0];
	}
	
	public function isReady() {
		return ctx != null;
	}
	
	public function selectShader( shader : Shader ) {
		var s = shader.getData();
		if( s.program == null ) {
			s.program = ctx.createProgram();
			var vdata = shader.getVertexProgram().getData();
			var fdata = shader.getFragmentProgram().getData();
			vdata.endian = flash.utils.Endian.LITTLE_ENDIAN;
			fdata.endian = flash.utils.Endian.LITTLE_ENDIAN;
			s.program.upload(vdata,fdata);
		}
		if( s != curShader ) {
			ctx.setProgram(s.program);
			// changing the program is so much costly that reuploading the variables should not make big difference anyway
			s.vertexVarsChanged = true;
			s.fragmentVarsChanged = true;
			// unbind extra textures
			var tcount : Int = s.textures.length;
			while( curTextures.length > tcount ) {
				curTextures.pop();
				ctx.setTextureAt(curTextures.length, null);
			}
			s.texturesChanged = true;
			// force remapping of vertex buffer
			if( curShader == null || s.bufferFormat != curShader.bufferFormat || s.stride != curShader.stride )
				curBuffer = null;
			curShader = s;
		}
		if( s.vertexVarsChanged ) {
			s.vertexVarsChanged = false;
			ctx.setProgramConstantsFromVector(flash.display3D.Context3DProgramType.VERTEX, 0, s.vertexVars);
		}
		if( s.fragmentVarsChanged ) {
			s.fragmentVarsChanged = false;
			ctx.setProgramConstantsFromVector(flash.display3D.Context3DProgramType.FRAGMENT, 0, s.fragmentVars);
		}
		if( s.texturesChanged ) {
			s.texturesChanged = false;
			for( i in 0...s.textures.length ) {
				var t = s.textures[i];
				if( t == null )
					throw "Texture #" + i + " not bound in shader " + shader;
				if( t != curTextures[i] ) {
					ctx.setTextureAt(i, t.t);
					curTextures[i] = t;
				}
			}
		}
	}
	
	public function selectMaterial( m : h3d.mat.Material ) {
		if( curMat != m ) {
			var old = curMat;
			if( m.blendDst != old.blendDst || m.blendSrc != old.blendSrc )
				ctx.setBlendFactors(BLEND[Type.enumIndex(m.blendSrc)], BLEND[Type.enumIndex(m.blendDst)]);
			if( m.culling != old.culling )
				ctx.setCulling(FACE[Type.enumIndex(m.culling)]);
			if( m.depthTest != old.depthTest || m.depthWrite != old.depthWrite )
				ctx.setDepthTest(m.depthWrite, COMPARE[Type.enumIndex(m.depthTest)]);
			if( m.colorMask != old.colorMask )
				ctx.setColorMask(m.colorMask & 1 != 0, m.colorMask & 2 != 0, m.colorMask & 4 != 0, m.colorMask & 8 != 0);
			curMat = m;
		}
		selectShader(m.shader);
	}
	
	function selectBuffer( buf : h3d.impl.MemoryManager.BigBuffer ) {
		if( buf == curBuffer )
			return;
		curBuffer = buf;
		if( buf.stride < curShader.stride )
			throw "Buffer stride (" + buf.stride + ") and shader "+curShader+" stride (" + curShader.stride + ") mismatch";
		if( !buf.written )
			mem.finalize(buf);
		var pos = 0, offset = 0;
		var bits = curShader.bufferFormat;
		while( offset < curShader.stride ) {
			var size = bits & 7;
			ctx.setVertexBufferAt(pos++, buf.vbuf, offset, FORMAT[size]);
			offset += size == 0 ? 1 : size;
			bits >>= 3;
		}
		for( i in pos...curAttributes )
			ctx.setVertexBufferAt(i, null);
		curAttributes = pos;
	}
	
	public function renderIndexes( b : h3d.impl.Buffer, indexes : h3d.impl.Indexes, vertPerTri : Int, startTri = 0, drawTri = -1 ) {
		do {
			var ntri = Std.int(b.nvert / vertPerTri);
			var pos = Std.int(b.pos / vertPerTri);
			if( startTri > 0 ) {
				if( startTri >= ntri ) {
					startTri -= ntri;
					b = b.next;
					continue;
				}
				pos += startTri;
				ntri -= startTri;
				startTri = 0;
			}
			if( drawTri >= 0 ) {
				if( drawTri == 0 ) return;
				drawTri -= ntri;
				if( drawTri < 0 ) {
					// maximize triangles to draw
					ntri += drawTri;
					drawTri = 0;
				} else if( b.next == null ) {
					// we request to draw more triangles than available !
					// force rendering remaining triangles
					// this is necessary when we have not-regular indexes
					// in that case, vertPerTri does not have a real meaning since it's the indexes size that matters
					ntri += drawTri;
				}
			}
			if( ntri > 0 ) {
				selectBuffer(b.b);
				ctx.drawTriangles(indexes.ibuf, pos * 3, ntri);
				drawTriangles += ntri;
				drawCalls++;
			}
			b = b.next;
		} while( b != null );
	}
	
	public inline function renderQuads( b : h3d.impl.Buffer ) {
		return renderIndexes(b, mem.quadIndexes, 2);
	}
	
	public inline function renderBuffer( b : h3d.impl.Buffer ) {
		return renderIndexes(b, mem.indexes, 3);
	}
	
	function setDebug(d) {
		debug = d;
		if( ctx != null ) ctx.enableErrorChecking = d && hardware;
		return d;
	}
	
	function onCreate() {
		ctx = s3d.context3D;
		mem = new h3d.impl.MemoryManager(ctx, 65400);
		hardware = ctx.driverInfo.toLowerCase().indexOf("software") == -1;
		setDebug(debug);
		resize(width, height);
		onReady();
	}
	
	public dynamic function onReady() {
	}
	
	public function resize(width, height, aa = 0) {
		this.width = width;
		this.height = height;
		ctx.configureBackBuffer(width, height, aa);
		camera.ratio = width / height;
	}
	
	public function begin() {
		if( ctx == null ) return false;
		try {
			ctx.clear( ((backgroundColor>>16)&0xFF)/255 , ((backgroundColor>>8)&0xFF)/255, (backgroundColor&0xFF)/255, ((backgroundColor>>>24)&0xFF)/255);
		} catch( e : Dynamic ) {
			ctx = null;
			return false;
		}
		
		// init
		drawTriangles = 0;
		drawCalls = 0;
		curMat = Type.createEmptyInstance(h3d.mat.Material);
		
		curShader = null;
		curBuffer = null;
		curTextures = [];
		return true;
	}
	
	public function end() {
		ctx.present();
		// reset
		curMat = null;
		curShader = null;
		curBuffer = null;
		for( i in 0...curAttributes )
			ctx.setVertexBufferAt(i, null);
		curAttributes = 0;
		for( i in 0...curTextures.length )
			ctx.setTextureAt(i, null);
		curTextures = [];
	}
	
	public function render( objects : Array<Object> ) {
		if( !begin() ) return false;
		for( o in objects )
			o.render(this);
		end();
		return true;
	}

	
	static var BLEND = [
		flash.display3D.Context3DBlendFactor.ONE,
		flash.display3D.Context3DBlendFactor.ZERO,
		flash.display3D.Context3DBlendFactor.SOURCE_ALPHA,
		flash.display3D.Context3DBlendFactor.SOURCE_COLOR,
		flash.display3D.Context3DBlendFactor.DESTINATION_ALPHA,
		flash.display3D.Context3DBlendFactor.DESTINATION_COLOR,
		flash.display3D.Context3DBlendFactor.ONE_MINUS_SOURCE_ALPHA,
		flash.display3D.Context3DBlendFactor.ONE_MINUS_SOURCE_COLOR,
		flash.display3D.Context3DBlendFactor.ONE_MINUS_DESTINATION_ALPHA,
		flash.display3D.Context3DBlendFactor.ONE_MINUS_DESTINATION_COLOR
	];

	static var FACE = [
		flash.display3D.Context3DTriangleFace.NONE,
		flash.display3D.Context3DTriangleFace.BACK,
		flash.display3D.Context3DTriangleFace.FRONT,
		flash.display3D.Context3DTriangleFace.FRONT_AND_BACK,
	];
	
	static var COMPARE = [
		flash.display3D.Context3DCompareMode.ALWAYS,
		flash.display3D.Context3DCompareMode.NEVER,
		flash.display3D.Context3DCompareMode.EQUAL,
		flash.display3D.Context3DCompareMode.NOT_EQUAL,
		flash.display3D.Context3DCompareMode.GREATER,
		flash.display3D.Context3DCompareMode.GREATER_EQUAL,
		flash.display3D.Context3DCompareMode.LESS,
		flash.display3D.Context3DCompareMode.LESS_EQUAL,
	];
	
	static var FORMAT = [
		flash.display3D.Context3DVertexBufferFormat.BYTES_4,
		flash.display3D.Context3DVertexBufferFormat.FLOAT_1,
		flash.display3D.Context3DVertexBufferFormat.FLOAT_2,
		flash.display3D.Context3DVertexBufferFormat.FLOAT_3,
		flash.display3D.Context3DVertexBufferFormat.FLOAT_4,
	];
}
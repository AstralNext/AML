import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Interactive 3D Minecraft player preview (drag to orbit).
///
/// Plays a light idle limb animation; camera does not auto-rotate.
class Skin3DViewer extends StatefulWidget {
  final Uint8List skinPng;
  final bool slim;
  final String? nametag;

  const Skin3DViewer({
    super.key,
    required this.skinPng,
    this.slim = false,
    this.nametag,
  });

  @override
  State<Skin3DViewer> createState() => _Skin3DViewerState();
}

class _Skin3DViewerState extends State<Skin3DViewer>
    with SingleTickerProviderStateMixin {
  ui.Image? _image;
  double _yaw = math.pi / 8;
  double _pitch = 0.15;
  late final AnimationController _idle;

  @override
  void initState() {
    super.initState();
    _idle = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
    _decode();
  }

  @override
  void didUpdateWidget(covariant Skin3DViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.skinPng != widget.skinPng) {
      _decode();
    }
  }

  Future<void> _decode() async {
    final codec = await ui.instantiateImageCodec(widget.skinPng);
    final frame = await codec.getNextFrame();
    if (!mounted) {
      frame.image.dispose();
      return;
    }
    setState(() {
      _image?.dispose();
      _image = frame.image;
    });
  }

  @override
  void dispose() {
    _idle.dispose();
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return AnimatedBuilder(
      animation: _idle,
      builder: (context, _) {
        final t = _idle.value * math.pi * 2;
        return GestureDetector(
          onPanUpdate: (d) {
            setState(() {
              _yaw += d.delta.dx * 0.012;
              _pitch = (_pitch + d.delta.dy * 0.012).clamp(-0.6, 0.6);
            });
          },
          child: CustomPaint(
            painter: _Skin3DPainter(
              image: image,
              slim: widget.slim,
              yaw: _yaw,
              pitch: _pitch,
              // Soft idle: opposite arm/leg swing + tiny body bob.
              rightArmSwing: math.sin(t) * 0.18,
              leftArmSwing: -math.sin(t) * 0.18,
              rightLegSwing: -math.sin(t) * 0.06,
              leftLegSwing: math.sin(t) * 0.06,
              bodyBob: math.sin(t * 2) * 0.35,
            ),
            child: const SizedBox.expand(),
          ),
        );
      },
    );
  }
}

class _Vec3 {
  final double x, y, z;
  const _Vec3(this.x, this.y, this.z);

  _Vec3 operator +(_Vec3 o) => _Vec3(x + o.x, y + o.y, z + o.z);
  _Vec3 operator -(_Vec3 o) => _Vec3(x - o.x, y - o.y, z - o.z);
  _Vec3 operator *(double s) => _Vec3(x * s, y * s, z * s);

  double get length => math.sqrt(x * x + y * y + z * z);

  _Vec3 normalized() {
    final l = length;
    if (l < 1e-9) return this;
    return this * (1 / l);
  }

  static _Vec3 cross(_Vec3 a, _Vec3 b) => _Vec3(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x,
      );
}

class _Face {
  final List<_Vec3> corners; // 4
  final Rect uv; // in skin pixels (64x64)
  final double depth;

  _Face(this.corners, this.uv, this.depth);
}

class _Skin3DPainter extends CustomPainter {
  final ui.Image image;
  final bool slim;
  final double yaw;
  final double pitch;
  final double rightArmSwing;
  final double leftArmSwing;
  final double rightLegSwing;
  final double leftLegSwing;
  final double bodyBob;

  _Skin3DPainter({
    required this.image,
    required this.slim,
    required this.yaw,
    required this.pitch,
    this.rightArmSwing = 0,
    this.leftArmSwing = 0,
    this.rightLegSwing = 0,
    this.leftLegSwing = 0,
    this.bodyBob = 0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final faces = <_Face>[];
    final armW = slim ? 3.0 : 4.0;

    _Vec3 swingAround(_Vec3 p, _Vec3 pivot, double angleX) {
      if (angleX.abs() < 1e-6) return p;
      var x = p.x - pivot.x;
      var y = p.y - pivot.y;
      var z = p.z - pivot.z;
      final c = math.cos(angleX);
      final s = math.sin(angleX);
      final y2 = y * c - z * s;
      final z2 = y * s + z * c;
      return _Vec3(x + pivot.x, y2 + pivot.y, z2 + pivot.z);
    }

    // Model space: Y up, units = skin pixels. Origin at feet center.
    void addBox({
      required _Vec3 origin, // min corner
      required double w,
      required double h,
      required double d,
      required _BoxUVs uvs,
      double inflate = 0,
      _Vec3? pivot,
      double swing = 0,
    }) {
      final o = _Vec3(
        origin.x - inflate,
        origin.y - inflate + bodyBob,
        origin.z - inflate,
      );
      final ww = w + inflate * 2;
      final hh = h + inflate * 2;
      final dd = d + inflate * 2;
      final piv = pivot == null
          ? null
          : _Vec3(pivot.x, pivot.y + bodyBob, pivot.z);

      _Vec3 c(double x, double y, double z) {
        var p = _Vec3(o.x + x, o.y + y, o.z + z);
        if (piv != null) p = swingAround(p, piv, swing);
        return p;
      }

      final p000 = c(0, 0, 0);
      final p100 = c(ww, 0, 0);
      final p010 = c(0, hh, 0);
      final p110 = c(ww, hh, 0);
      final p001 = c(0, 0, dd);
      final p101 = c(ww, 0, dd);
      final p011 = c(0, hh, dd);
      final p111 = c(ww, hh, dd);

      void face(List<_Vec3> corners, Rect uv) {
        final rotated = corners.map(_rotate).toList();
        final depth = rotated
                .map((p) => p.z)
                .reduce((a, b) => a + b) /
            rotated.length;
        final e1 = rotated[1] - rotated[0];
        final e2 = rotated[2] - rotated[0];
        final n = _Vec3.cross(e1, e2);
        if (n.z <= 0) return;
        faces.add(_Face(rotated, uv, depth));
      }

      face([p001, p101, p111, p011], uvs.front);
      face([p100, p000, p010, p110], uvs.back);
      face([p000, p001, p011, p010], uvs.right);
      face([p101, p100, p110, p111], uvs.left);
      face([p011, p111, p110, p010], uvs.top);
      face([p000, p100, p101, p001], uvs.bottom);
    }

    final rightArmPivot = _Vec3(-4 - armW / 2, 22, 0);
    final leftArmPivot = _Vec3(4 + armW / 2, 22, 0);
    const rightLegPivot = _Vec3(-2, 12, 0);
    const leftLegPivot = _Vec3(2, 12, 0);

    // Inner layer
    addBox(
      origin: const _Vec3(-4, 24, -4),
      w: 8,
      h: 8,
      d: 8,
      uvs: _BoxUVs.head,
    );
    addBox(
      origin: const _Vec3(-4, 12, -2),
      w: 8,
      h: 12,
      d: 4,
      uvs: _BoxUVs.body,
    );
    addBox(
      origin: _Vec3(-4 - armW, 12, -2),
      w: armW,
      h: 12,
      d: 4,
      uvs: slim ? _BoxUVs.rightArmSlim : _BoxUVs.rightArm,
      pivot: rightArmPivot,
      swing: rightArmSwing,
    );
    addBox(
      origin: const _Vec3(4, 12, -2),
      w: armW,
      h: 12,
      d: 4,
      uvs: slim ? _BoxUVs.leftArmSlim : _BoxUVs.leftArm,
      pivot: leftArmPivot,
      swing: leftArmSwing,
    );
    addBox(
      origin: const _Vec3(-4, 0, -2),
      w: 4,
      h: 12,
      d: 4,
      uvs: _BoxUVs.rightLeg,
      pivot: rightLegPivot,
      swing: rightLegSwing,
    );
    addBox(
      origin: const _Vec3(0, 0, -2),
      w: 4,
      h: 12,
      d: 4,
      uvs: _BoxUVs.leftLeg,
      pivot: leftLegPivot,
      swing: leftLegSwing,
    );

    // Outer layer
    addBox(
      origin: const _Vec3(-4, 24, -4),
      w: 8,
      h: 8,
      d: 8,
      inflate: 0.5,
      uvs: _BoxUVs.hat,
    );
    addBox(
      origin: const _Vec3(-4, 12, -2),
      w: 8,
      h: 12,
      d: 4,
      inflate: 0.25,
      uvs: _BoxUVs.jacket,
    );
    addBox(
      origin: _Vec3(-4 - armW, 12, -2),
      w: armW,
      h: 12,
      d: 4,
      inflate: 0.25,
      uvs: slim ? _BoxUVs.rightSleeveSlim : _BoxUVs.rightSleeve,
      pivot: rightArmPivot,
      swing: rightArmSwing,
    );
    addBox(
      origin: const _Vec3(4, 12, -2),
      w: armW,
      h: 12,
      d: 4,
      inflate: 0.25,
      uvs: slim ? _BoxUVs.leftSleeveSlim : _BoxUVs.leftSleeve,
      pivot: leftArmPivot,
      swing: leftArmSwing,
    );
    addBox(
      origin: const _Vec3(-4, 0, -2),
      w: 4,
      h: 12,
      d: 4,
      inflate: 0.25,
      uvs: _BoxUVs.rightPants,
      pivot: rightLegPivot,
      swing: rightLegSwing,
    );
    addBox(
      origin: const _Vec3(0, 0, -2),
      w: 4,
      h: 12,
      d: 4,
      inflate: 0.25,
      uvs: _BoxUVs.leftPants,
      pivot: leftLegPivot,
      swing: leftLegSwing,
    );

    faces.sort((a, b) => a.depth.compareTo(b.depth));

    final cx = size.width / 2;
    final cy = size.height * 0.58;
    final scale = math.min(size.width, size.height) / 42;

    final shader = ImageShader(
      image,
      TileMode.clamp,
      TileMode.clamp,
      Matrix4.identity().storage,
    );
    final paint = Paint()
      ..shader = shader
      ..isAntiAlias = false
      ..filterQuality = FilterQuality.none;

    for (final face in faces) {
      final pts = face.corners
          .map((p) => Offset(cx + p.x * scale, cy - p.y * scale))
          .toList();
      final u = face.uv;
      final uvs = <Offset>[
        Offset(u.left, u.bottom),
        Offset(u.right, u.bottom),
        Offset(u.right, u.top),
        Offset(u.left, u.bottom),
        Offset(u.right, u.top),
        Offset(u.left, u.top),
      ];
      final positions = <Offset>[
        pts[0],
        pts[1],
        pts[2],
        pts[0],
        pts[2],
        pts[3],
      ];
      canvas.drawVertices(
        ui.Vertices(
          VertexMode.triangles,
          positions,
          textureCoordinates: uvs,
        ),
        BlendMode.srcOver,
        paint,
      );
    }
  }

  _Vec3 _rotate(_Vec3 p) {
    var x = p.x;
    var y = p.y - 16;
    var z = p.z;

    final cosP = math.cos(pitch);
    final sinP = math.sin(pitch);
    final y1 = y * cosP - z * sinP;
    final z1 = y * sinP + z * cosP;
    y = y1;
    z = z1;

    final cosY = math.cos(yaw);
    final sinY = math.sin(yaw);
    final x2 = x * cosY + z * sinY;
    final z2 = -x * sinY + z * cosY;
    return _Vec3(x2, y, z2);
  }

  @override
  bool shouldRepaint(covariant _Skin3DPainter old) =>
      old.image != image ||
      old.slim != slim ||
      old.yaw != yaw ||
      old.pitch != pitch ||
      old.rightArmSwing != rightArmSwing ||
      old.leftArmSwing != leftArmSwing ||
      old.rightLegSwing != rightLegSwing ||
      old.leftLegSwing != leftLegSwing ||
      old.bodyBob != bodyBob;
}

/// Minecraft 64×64 UV boxes (pixel rects).
class _BoxUVs {
  final Rect top, bottom, right, front, left, back;

  const _BoxUVs({
    required this.top,
    required this.bottom,
    required this.right,
    required this.front,
    required this.left,
    required this.back,
  });

  static Rect r(double x, double y, double w, double h) =>
      Rect.fromLTWH(x, y, w, h);

  // Head 8x8x8 @ (0,0)
  static final head = _BoxUVs(
    top: r(8, 0, 8, 8),
    bottom: r(16, 0, 8, 8),
    right: r(0, 8, 8, 8),
    front: r(8, 8, 8, 8),
    left: r(16, 8, 8, 8),
    back: r(24, 8, 8, 8),
  );
  static final hat = _BoxUVs(
    top: r(40, 0, 8, 8),
    bottom: r(48, 0, 8, 8),
    right: r(32, 8, 8, 8),
    front: r(40, 8, 8, 8),
    left: r(48, 8, 8, 8),
    back: r(56, 8, 8, 8),
  );

  // Body 8x12x4 @ (16,16)
  static final body = _BoxUVs(
    top: r(20, 16, 8, 4),
    bottom: r(28, 16, 8, 4),
    right: r(16, 20, 4, 12),
    front: r(20, 20, 8, 12),
    left: r(32, 20, 4, 12),
    back: r(28, 20, 8, 12),
  );
  static final jacket = _BoxUVs(
    top: r(20, 32, 8, 4),
    bottom: r(28, 32, 8, 4),
    right: r(16, 36, 4, 12),
    front: r(20, 36, 8, 12),
    left: r(32, 36, 4, 12),
    back: r(28, 36, 8, 12),
  );

  // Right arm classic 4x12x4 @ (40,16)
  static final rightArm = _BoxUVs(
    top: r(44, 16, 4, 4),
    bottom: r(48, 16, 4, 4),
    right: r(40, 20, 4, 12),
    front: r(44, 20, 4, 12),
    left: r(48, 20, 4, 12),
    back: r(52, 20, 4, 12),
  );
  static final rightSleeve = _BoxUVs(
    top: r(44, 32, 4, 4),
    bottom: r(48, 32, 4, 4),
    right: r(40, 36, 4, 12),
    front: r(44, 36, 4, 12),
    left: r(48, 36, 4, 12),
    back: r(52, 36, 4, 12),
  );

  // Right arm slim 3x12x4 @ (40,16)
  static final rightArmSlim = _BoxUVs(
    top: r(44, 16, 3, 4),
    bottom: r(47, 16, 3, 4),
    right: r(40, 20, 4, 12),
    front: r(44, 20, 3, 12),
    left: r(47, 20, 4, 12),
    back: r(51, 20, 3, 12),
  );
  static final rightSleeveSlim = _BoxUVs(
    top: r(44, 32, 3, 4),
    bottom: r(47, 32, 3, 4),
    right: r(40, 36, 4, 12),
    front: r(44, 36, 3, 12),
    left: r(47, 36, 4, 12),
    back: r(51, 36, 3, 12),
  );

  // Left arm classic @ (32,48)
  static final leftArm = _BoxUVs(
    top: r(36, 48, 4, 4),
    bottom: r(40, 48, 4, 4),
    right: r(32, 52, 4, 12),
    front: r(36, 52, 4, 12),
    left: r(40, 52, 4, 12),
    back: r(44, 52, 4, 12),
  );
  static final leftSleeve = _BoxUVs(
    top: r(52, 48, 4, 4),
    bottom: r(56, 48, 4, 4),
    right: r(48, 52, 4, 12),
    front: r(52, 52, 4, 12),
    left: r(56, 52, 4, 12),
    back: r(60, 52, 4, 12),
  );

  static final leftArmSlim = _BoxUVs(
    top: r(36, 48, 3, 4),
    bottom: r(39, 48, 3, 4),
    right: r(32, 52, 4, 12),
    front: r(36, 52, 3, 12),
    left: r(39, 52, 4, 12),
    back: r(43, 52, 3, 12),
  );
  static final leftSleeveSlim = _BoxUVs(
    top: r(52, 48, 3, 4),
    bottom: r(55, 48, 3, 4),
    right: r(48, 52, 4, 12),
    front: r(52, 52, 3, 12),
    left: r(55, 52, 4, 12),
    back: r(59, 52, 3, 12),
  );

  // Legs
  static final rightLeg = _BoxUVs(
    top: r(4, 16, 4, 4),
    bottom: r(8, 16, 4, 4),
    right: r(0, 20, 4, 12),
    front: r(4, 20, 4, 12),
    left: r(8, 20, 4, 12),
    back: r(12, 20, 4, 12),
  );
  static final rightPants = _BoxUVs(
    top: r(4, 32, 4, 4),
    bottom: r(8, 32, 4, 4),
    right: r(0, 36, 4, 12),
    front: r(4, 36, 4, 12),
    left: r(8, 36, 4, 12),
    back: r(12, 36, 4, 12),
  );
  static final leftLeg = _BoxUVs(
    top: r(20, 48, 4, 4),
    bottom: r(24, 48, 4, 4),
    right: r(16, 52, 4, 12),
    front: r(20, 52, 4, 12),
    left: r(24, 52, 4, 12),
    back: r(28, 52, 4, 12),
  );
  static final leftPants = _BoxUVs(
    top: r(4, 48, 4, 4),
    bottom: r(8, 48, 4, 4),
    right: r(0, 52, 4, 12),
    front: r(4, 52, 4, 12),
    left: r(8, 52, 4, 12),
    back: r(12, 52, 4, 12),
  );
}

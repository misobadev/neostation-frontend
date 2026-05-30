import 'package:flutter/material.dart';

enum CarouselPageChangeReason { manual, controller }

class NativeCarousel extends StatefulWidget {
  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final void Function(int index, CarouselPageChangeReason reason)?
  onPageChanged;
  final ValueChanged<double>? onPageScrolled;
  final int initialIndex;

  const NativeCarousel({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.onPageChanged,
    this.onPageScrolled,
    this.initialIndex = 0,
  });

  @override
  State<NativeCarousel> createState() => NativeCarouselState();
}

class NativeCarouselState extends State<NativeCarousel> {
  PageController? _pageController;
  int _currentIndex = 0;
  double _lastVpFraction = 0;
  int _lastReportedIndex = 0;
  final ValueNotifier<double> _pageNotifier = ValueNotifier(0.0);
  CarouselPageChangeReason _pageChangeReason =
      CarouselPageChangeReason.controller;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _lastReportedIndex = widget.initialIndex;
    _pageNotifier.value = widget.initialIndex.toDouble();
  }

  @override
  void didUpdateWidget(NativeCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialIndex != oldWidget.initialIndex &&
        widget.initialIndex != _currentIndex &&
        _pageController != null) {
      _animateToPage(widget.initialIndex);
    }
  }

  @override
  void dispose() {
    _pageController?.removeListener(_onPageScroll);
    _pageController?.dispose();
    _pageNotifier.dispose();
    super.dispose();
  }

  void _onPageScroll() {
    final page = _pageController?.page;
    if (page == null) return;

    _pageNotifier.value = page;
    _currentIndex = page.round();
    widget.onPageScrolled?.call(page);

    if (_currentIndex != _lastReportedIndex) {
      final dist = (page - _currentIndex).abs();
      if (dist < 0.05) {
        _lastReportedIndex = _currentIndex;
        final reason = _pageChangeReason;
        _pageChangeReason = CarouselPageChangeReason.controller;
        widget.onPageChanged?.call(_currentIndex, reason);
      }
    }
  }

  void _ensureController(double vpFraction) {
    if (_pageController == null || vpFraction != _lastVpFraction) {
      _pageController?.removeListener(_onPageScroll);
      _pageController?.dispose();
      _lastVpFraction = vpFraction;
      _pageController = PageController(
        viewportFraction: vpFraction,
        initialPage: _currentIndex,
      );
      _pageController!.addListener(_onPageScroll);
      _lastReportedIndex = _currentIndex;
    }
  }

  void nextPage() {
    if (_currentIndex < widget.itemCount - 1) {
      _animateToPage(_currentIndex + 1);
    }
  }

  void previousPage() {
    if (_currentIndex > 0) {
      _animateToPage(_currentIndex - 1);
    }
  }

  void _animateToPage(int index) {
    _pageChangeReason = CarouselPageChangeReason.controller;
    _pageController?.animateToPage(
      index,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutQuart,
    );
  }

  void jumpToPage(int index) {
    _pageChangeReason = CarouselPageChangeReason.controller;
    _pageController?.jumpToPage(index);
  }

  void animateToPage(int index) {
    if (index >= 0 && index < widget.itemCount) {
      _animateToPage(index);
    }
  }

  int get currentIndex => _currentIndex;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth;
        // Calculate viewportFraction so each page is square sized to fill height.
        // Page width = available height (square), fraction = pageWidth / viewportWidth.
        final oneCardFraction = (availableWidth > 0)
            ? constraints.maxHeight / availableWidth
            : 0.3;
        final vpFraction = oneCardFraction.clamp(0.18, 1.0);

        _ensureController(vpFraction);

        return SizedBox(
          height: constraints.maxHeight,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) {
              _pageChangeReason = CarouselPageChangeReason.manual;
            },
            child: PageView.builder(
              controller: _pageController,
              clipBehavior: Clip.none,
              padEnds: true,
              allowImplicitScrolling: true,
              itemCount: widget.itemCount,
              itemBuilder: (context, index) {
                return ValueListenableBuilder<double>(
                  valueListenable: _pageNotifier,
                  builder: (context, page, _) {
                    final distance = (index - page).abs() - 0.6;
                    final scale = (1.0 - distance * 0.4).clamp(0.25, 1.0);
                    final opacity = (0.6 - distance * 1).clamp(0.1, 1.0);

                    return Opacity(
                      opacity: opacity,
                      child: Transform.scale(
                        scale: scale,
                        alignment: Alignment.center,
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: widget.itemBuilder(context, index),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }
}

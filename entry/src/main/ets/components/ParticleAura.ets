@Component
export struct ParticleAura {
  @StorageProp('vividForeground') private foreground: boolean = true;

  build() {
    if (this.foreground) {
    Particle({
      particles: [{
        emitter: {
          particle: {
            type: ParticleType.POINT,
            // A small GPU particle field keeps the API 26 background alive
            // without competing with the editor's image processing thread.
            config: { radius: 2.2 },
            count: 40,
            lifetime: 6200,
            lifetimeRange: 1800,
          },
          emitRate: 5,
          shape: ParticleEmitterShape.RECTANGLE,
          position: [0, 0],
          size: ['100%', '100%'],
        },
        color: {
          range: ['#7395FF', '#E7A4FF'],
        },
        opacity: {
          range: [0.12, 0.36],
          updater: {
            type: ParticleUpdater.CURVE,
            config: [
              { from: 0.0, to: 0.34, startMillis: 0, endMillis: 1600 },
              { from: 0.34, to: 0.0, startMillis: 1600, endMillis: 6200 },
            ],
          },
        },
        scale: {
          range: [0.6, 1.8],
          updater: {
            type: ParticleUpdater.RANDOM,
            config: [0.8, 1.2],
          },
        },
        velocity: {
          speed: [2, 10],
          angle: [205, 335],
        },
      }],
    })
      .width('100%')
      .height('100%')
      .opacity(0.82)
      .hitTestBehavior(HitTestMode.None);
    }
  }
}

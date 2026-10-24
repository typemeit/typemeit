import { useEffect, useState } from 'react';
import { continueRender, delayRender, staticFile } from 'remotion';

/// DM Mono, the landing page's face, for captions and the end card.
export const useBrandFonts = () => {
  const [handle] = useState(() => delayRender('fonts'));
  useEffect(() => {
    const faces = [
      new FontFace('DM Mono', `url(${staticFile('fonts/DMMono-Regular.ttf')})`, { weight: '400' }),
      new FontFace('DM Mono', `url(${staticFile('fonts/DMMono-Medium.ttf')})`, { weight: '500' }),
    ];
    Promise.all(faces.map((face) => face.load())).then((loaded) => {
      loaded.forEach((face) => document.fonts.add(face));
      continueRender(handle);
    });
  }, [handle]);
};

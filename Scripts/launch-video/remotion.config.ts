import { Config } from '@remotion/cli/config';

Config.setVideoImageFormat('jpeg');
Config.setOverwriteOutput(true);
Config.setCodec('h264');
Config.setCrf(18);
// The puff is drawn with WebGL2, which headless Chrome renders on the GPU through ANGLE.
Config.setChromiumOpenGlRenderer('angle');

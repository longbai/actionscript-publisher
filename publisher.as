package {
  import flash.display.Sprite;
  import flash.display.StageAlign;
  import flash.display.StageScaleMode;
  import flash.events.Event;
  import flash.events.StatusEvent;
  import flash.events.NetStatusEvent;
  import flash.external.ExternalInterface;
  import flash.media.Camera;
  import flash.media.Microphone;
  import flash.media.Video;
  import flash.net.NetConnection;
  import flash.net.NetStream;
  import flash.net.NetStreamInfo;
  import flash.net.ObjectEncoding;
  import flash.media.VideoStreamSettings;
  import flash.media.H264VideoStreamSettings;
  import flash.media.H264Level;
  import flash.media.H264Profile;
  import flash.media.SoundCodec;
  import mx.utils.ObjectUtil;
  import flash.utils.getTimer;
  import flash.utils.setTimeout;
  import flash.system.Security;
  import flash.system.SecurityPanel;

  Security.allowDomain('*');

  public class publisher extends Sprite {
    protected var video:Video;
    protected var connection:NetConnection;
    protected var netStream:NetStream;
    protected var camera:Camera;
    protected var microphone:Microphone;
    protected var options:Object = {
      serverURL: null
    , streamName: null
    , streamWidth: 1280
    , streamHeight: 720
    , streamFPS: 30
    , keyFrameInterval: 120
    // http://help.adobe.com/en_US/AS2LCR/Flash_10.0/help.html?content=00000880.html
    , bandwidth: 2048 * 1024              // BYTES per second (not bits per second)
    , videoQuality: 0                     // % percentage

    , videoCodec: "Sorensen"              // options: Sorensen|H264Avc
    , h264Profile: H264Profile.MAIN       // only valid when videoCodec is H264Avc
    , h264Level: H264Level.LEVEL_3_1      // only valid when videoCodec is H264Avc
    , audioCodec: SoundCodec.NELLYMOSER   // options: NellyMoser|Speex
    , audioSampleRate: 44                 // kHz
    , microphoneSilenceLevel: 0
    , microphoneLoopBack: false
    , jsLogFunction: "console.log"
    , jsEmitFunction: null
    , embedTimecode: true
    , timecodeFrequency: 1000
    , statusFrequency: 1000
    , favorArea: false // http//help.adobe.com/en_US/FlashPlatform/reference/actionscript/3/flash/media/Camera.html#setMode()
    };

    /**
     * the timestamp of when the recording started.
     */
    protected var _recordStartTime:uint;
    protected var _isPreviewing:Boolean = false;
    protected var _isPublishing:Boolean = false;
    protected var _isConnecting:Boolean = false;
    // _cameraStreaming is changed when the user clicks allow, or it is already allowed
    // we need this because otherwise ffmpeg detects an audio stream
    // and a data stream
    // and it then drops the video stream on the floor
    // so we need to wait for the video stream to start streaming
    // then we can start sending data
    protected var _hasMediaAccess:Boolean = false;

    public function publisher() {
      log("Initializing ...");

      stage.align = StageAlign.TOP_LEFT;
      stage.scaleMode = StageScaleMode.NO_SCALE;
      stage.addEventListener(Event.RESIZE, this.onResize)

      if (ExternalInterface.available) {
        ExternalInterface.addCallback("trace", this.log);
        ExternalInterface.addCallback("getOptions", this.getOptions);
        ExternalInterface.addCallback("setOptions", this.setOptions);
        ExternalInterface.addCallback("getMediaInfo", this.getMediaInfo);
        ExternalInterface.addCallback("selectMicrophone", this.selectMicrophone);
        ExternalInterface.addCallback("selectCamera", this.selectCamera);
        ExternalInterface.addCallback("sendData", this.sendTextData);
        ExternalInterface.addCallback("sendCuePoint", this.sendCuePoint);
        ExternalInterface.addCallback("start", this.start);
        ExternalInterface.addCallback("stop", this.stop);
        ExternalInterface.addCallback("preview", this.preview);
        ExternalInterface.addCallback("getInfo", this.getInfo);
      } else {
        log("External interface not available.");
      }
    }

    private function onResize(e:Event):void {
      log("Resizing video", stage.stageWidth, 'x', stage.stageHeight);
      createVideo();
    }

    // https://github.com/KAPx/krecord/compare/KAPx:kapx...kapx-rtmp-timecode-events
    private function embedTimecode():void {
      if (!this._isPublishing){
        return;
      }
      var timeCode:uint = getTimer() - _recordStartTime;
      var now:Date = new Date();
      var msTimeStamp:Number = now.getTime();
      // log('embedTimecode: offset - ' + timeCode.toString() + " time - "+ msTimeStamp);
      sendTextData({ timecode: timeCode, timestamp: msTimeStamp });
      setTimeout(embedTimecode, this.options.timecodeFrequency);
    }

    private function emitStatus():void {
      if (!this._isPublishing){
        return;
      }
      // http://help.adobe.com/en_US/FlashPlatform/reference/actionscript/3/flash/net/NetStreamInfo.html
      var info:NetStreamInfo = this.netStream.info;

      var timeCode:uint = getTimer() - _recordStartTime;
      var now:Date = new Date();
      var msTimeStamp:Number = now.getTime();

      emit({
        kind: "status",
        code: 110,
        bandwidth: {
          audio: (info.audioBytesPerSecond / 1024),
          video: (info.videoBytesPerSecond / 1024),
          data: (info.dataBytesPerSecond / 1024),
          total: (info.currentBytesPerSecond / 1024)
        },
        fps: this.camera.currentFPS,
        droppedFrames: info.droppedFrames,
        timecode: timeCode,
        timestamp: msTimeStamp
      });
      setTimeout(emitStatus, this.options.statusFrequency);
    }


    public function sendCuePoint(cuePointData:Object):Boolean {
      return sendData("onCuePoint", cuePointData);
    }

    public function getMediaInfo():Object{
      return {cameras: Camera.names, microphones: Microphone.names};
    }

    public function selectMicrophone():void{
      Security.showSettings(SecurityPanel.MICROPHONE);
    }

    public function selectCamera():void{
      Security.showSettings(SecurityPanel.CAMERA);
    }

    public function getInfo():Object{
      return {version: "0.2.5"}
    }

    /**
     * Send an 'onTextData' message on the NetStream.
     */
    public function sendTextData(data:Object):Boolean{
        if (!('text' in data)) {
          data.text = '';
        }
        if (!('language' in data)) {
          data.language = 'eng';
        }
        return sendData("onTextData", data);
    }

    private function sendData(handle:String, data:Object):Boolean{
      if (!_hasMediaAccess) {
        return false;
      }
      if (!_isPublishing) {
        return false;
      }
      // log("sending data - " + ObjectUtil.toString(data));
      this.netStream.send(handle, data);
      return true;
    }

    // log to the JavaScript console
    public function log(... arguments):void {
      if (options.jsLogFunction == null){
        return;
      }
      var applyArgs:Array = [options.jsLogFunction, "publisher:"].concat(arguments);
      ExternalInterface.call.apply(this, applyArgs);
    }

    // log to the JavaScript console
    public function emit(emitObject:Object):void {
      if (options.jsEmitFunction == null){
        return;
      }
      ExternalInterface.call.apply(this, [options.jsEmitFunction, emitObject]);
    }


    // External APIs -- invoked from JavaScript

    public function getOptions():Object {
      return this.options;
    }

    public function setOptions(options:Object):void {
      log("Received options:", options)
      for(var p:String in options) {
        if (options[p] != null) {
          this.options[p] = options[p];
        }
      }
    }

    public function start():Boolean {
      if (this._isConnecting){
        return false;
      }
      this.connection = new NetConnection();
      this.connection.objectEncoding = ObjectEncoding.AMF0;
      this.connection.addEventListener(NetStatusEvent.NET_STATUS, onNetStatus, false, 0, true);

      emit({kind: "status", code: 100, message: "Connecting to url: " + this.options.serverURL});
      this.connection.connect(this.options.serverURL);

      this._isConnecting = true;
      return true;
    }

    // This removes the existing video and
    // and recreates a new video
    public function createVideo():void {
      var videoDimensions:Object = getVideoDimensions();
      log("Video dimensions:", videoDimensions.width, "x", videoDimensions.height);
      this.video = new Video(videoDimensions.width, videoDimensions.height);
      // remove video if already exists
      if (this.numChildren > 0) { this.removeChildAt(0); }
      this.addChild(this.video);

      // attach the camera to the video
      this.video.attachCamera(camera);
    }

    public function preview():Boolean {
      emit({kind: "status", code: 101, message: "Previewing."});
      if(this._isPreviewing){
        return false;
      }

      // set up the camera and video object
      this.microphone = getMicrophone();
      this.camera = getCamera();
      this._hasMediaAccess = !camera.muted;
      camera.addEventListener(StatusEvent.STATUS, onCameraStatus);

      createVideo();

      this._isPreviewing = true;
      return true;
    }

    public function stop():void {
      log("closing net stream");
      if (this.netStream) {
        this.netStream.close();
        this.netStream = null;
      }
      log("closing video");
      if (this.video){
        this.video.clear();
        this.video.attachCamera(null);
      }
      log("closing clearing variables");
      isDisconnected();
      this._isPreviewing = false;

      log("closing connection");
      if (this.connection && this.connection.connected) {
        this.connection.close();
      }
    }

    private function isDisconnected():void{
      this._isConnecting = false;
      this._isPublishing = false;
    }

    // set up the microphone and camera

    private function getMicrophone():Microphone {
      var microphone:Microphone = Microphone.getMicrophone();
      microphone.codec = this.options.audioCodec;
      microphone.rate = this.options.audioSampleRate;
      microphone.setSilenceLevel(this.options.microphoneSilenceLevel);
      microphone.setLoopBack(this.options.microphoneLoopBack)

      log("Audio Codec:", this.options.audioCodec);
      log("Audio Sample Rate:", this.options.audioSampleRate);
      log("Microphone Silence Level:", this.options.microphoneSilenceLevel);
      log("Microphone Loopback:", this.options.microphoneLoopback);

      return microphone;
    }

    private function getCamera():Camera {
      var camera:Camera = Camera.getCamera();
      // http://help.adobe.com/en_US/FlashPlatform/reference/actionscript/3/flash/media/Camera.html#setMode()
      camera.setMode(this.options.streamWidth, this.options.streamHeight, this.options.streamFPS, this.options.favorArea);
      // http://help.adobe.com/en_US/AS2LCR/Flash_10.0/help.html?content=00000880.html
      camera.setQuality(this.options.bandwidth, this.options.videoQuality);
      camera.setKeyFrameInterval(this.options.keyFrameInterval);

      return camera;
    }

    private function getVideoStreamSettings():VideoStreamSettings {
      // configure streaming settings -- match to camera settings
      var videoStreamSettings:VideoStreamSettings;
      if (this.options.videoCodec == "H264Avc") {
        var h264VideoStreamSettings:H264VideoStreamSettings = new H264VideoStreamSettings();
        h264VideoStreamSettings.setProfileLevel(this.options.h264Profile, this.options.h264Level);
        videoStreamSettings = h264VideoStreamSettings;
      } else {
        videoStreamSettings = new VideoStreamSettings();
      }
      videoStreamSettings.setQuality(this.options.bandwidth, this.options.videoQuality);
      videoStreamSettings.setKeyFrameInterval(this.options.keyFrameInterval);
      videoStreamSettings.setMode(this.options.streamWidth, this.options.streamHeight, this.options.streamFPS);

      log("Video Codec:", videoStreamSettings.codec);
      if (videoStreamSettings.codec == "H264Avc") {
        log("H264 Profile:", this.options.h264Profile);
        log("H264 Level:", this.options.h264Level);
      }
      log("Resolution:", this.options.streamWidth, "x", this.options.streamHeight);
      log("Frame rate:", this.options.streamFPS, "fps");
      log("Keyframe interval:", this.options.keyFrameInterval);
      log("Bandwidth:", this.options.bandwidth, "bps");
      log("Quality:", this.options.videoQuality, "%");

      return videoStreamSettings;
    }


    private function getVideoDimensions():Object {
      log("Stage dimensions:", stage.stageWidth, "x", stage.stageHeight);
      var width:int, height:int;
      var stageAR:Number = stage.stageWidth / stage.stageHeight;
      var streamAR:Number = this.options.streamWidth / this.options.streamHeight;
      if (streamAR >= stageAR) { // too wide
        width = stage.stageWidth;
        height = Math.round(width / streamAR);
      } else if (streamAR < stageAR) { // too tall
        height = stage.stageHeight;
        width = Math.round(height * streamAR);
      }

      return {
        width: width
      , height: height
      };
    }


    // publish the stream to the server
    private function publish():void {
      emit({kind: "status", code: 102, message: "About to publish stream ..."});

      try {
        preview();

        // attach the camera and microphone to the stream
        this.netStream = new NetStream(this.connection);
        this.netStream.addEventListener(NetStatusEvent.NET_STATUS, onNetStatus, false, 0, true);

        this.netStream.attachCamera(this.camera);
        this.netStream.attachAudio(this.microphone);
        this.netStream.videoStreamSettings = getVideoStreamSettings();
        log("Video Codec:", this.netStream.videoStreamSettings.codec);

        // start publishing the stream
        if (this._hasMediaAccess){
          startPublishing();
        }
      } catch (err:Error) {
        log("ERROR:", err);
        emit({kind: "error", message: err});
      }
    }

    private function sendMetaData():void {
      var metaData:Object = new Object();
      metaData.title = this.options.streamName;
      metaData.width = this.options.streamWidth;
      metaData.height = this.options.streamHeight;
      metaData.displayWidth = this.options.streamWidth;
      metaData.displayHeight = this.options.streamHeight;
      metaData.fps = this.options.streamFPS;
      metaData.audiocodecid = this.getAudioCodecId();
      metaData.videocodecid = this.getVideoCodecId();
      if (this.netStream.videoStreamSettings.codec == "H264Avc") {
        metaData.profile = this.options.h264Profile;
        metaData.level = this.options.h264Level;
      }
      emit({kind: "status", code: 103, message: "Sending stream metadata.", metaData: metaData});

      this.netStream.send( "@setDataFrame", "onMetaData", metaData);
    }

    // http://help.adobe.com/en_US/flashmediaserver/devguide/WS5b3ccc516d4fbf351e63e3d11a0773d56e-7ff6Dev.html
    private function getAudioCodecId():Number{
      log("audioCodec", this.options.audioCodec);
      switch (this.options.audioCodec) {
        case "Uncompressed":
          return 0;
        case "ADPCM":
          return 1;
        case "MP3":
          return 2;
        case "Nellymoser 8 kHz Mono":
          return 5;
        case "Nellymoser":
          return 6;
        // we pass in NellyMoser
        case "NellyMoser":
          return 6;
        case "HE-AAC":
          return 10;
        case "Speex":
          return 11;
      }
      return -1;
    }
    // http://help.adobe.com/en_US/flashmediaserver/devguide/WS5b3ccc516d4fbf351e63e3d11a0773d56e-7ff6Dev.html
    private function getVideoCodecId():Number{
      log("videoCodec", this.options.videoCodec);

      switch (this.options.videoCodec) {
        case "Sorensen":
          return 2;
        case "H264Avc":
          return 7;
      }
      return -1;
    }

    private function onCameraStatus(event:StatusEvent):void {
      switch (event.code) {
        case "Camera.Muted":
          trace("User clicked Deny.");
          break;
        case "Camera.Unmuted":
          this._hasMediaAccess = true;
          startPublishing();
          trace("User clicked Accept.");
          break;
        }
    }

    private function startPublishing():void{
      try {
        log("Publishing to:", this.options.streamName);
        // set the initial timer
        this._recordStartTime = getTimer()
        this.netStream.publish(this.options.streamName);

        if (this.options.embedTimecode) {
          trace('embedding recording timecode');
          setTimeout(embedTimecode, this.options.timecodeFrequency);
        }
        setTimeout(emitStatus, this.options.statusFrequency);
      } catch (err:Error) {
        log("ERROR:", err);
        emit({kind: "error", message: err});
      }
    }

    // respond to network status events
    private function onNetStatus(event1:NetStatusEvent):void {
      switch (event1.info.code) {
        case "NetConnection.Connect.Success":
          emit({kind: "connect", code: 200, message: "Connected to the RTMP server."});
          publish();
          break;
        case "NetConnection.Connect.Failed":
          isDisconnected();
          emit({kind: "disconnect", code: 501, message: "Couldn't connect to the RTMP server."});
          break;

        case "NetConnection.Connect.Closed":
          isDisconnected();
          emit({kind: "disconnect", code: 502, message: "Disconnected from the RTMP server."});
          break;

        case "NetStream.Publish.Start":
          this._isPublishing = true;
          // send metadata immediately after Publish.Start
          // https://forums.adobe.com/thread/629972?tstart=0
          sendMetaData();
          emit({kind: "connect", code: 201, message: "Publishing started."})
          break;

        case "NetStream.Failed":
          stop();
          emit({kind: "error", code: 503, message: "Couldn't stream to endpoint (fail)."});
          break;

        case "NetStream.Publish.Denied":
          stop();
          emit({kind: "error", code: 504, message: "Couldn't stream to endpoint (deny)."});
          break;

        default:
          log("NetStatusEvent: " + event1.info.code);
          break;
      }
    }
  }
}

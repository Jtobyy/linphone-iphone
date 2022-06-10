/*
* Copyright (c) 2010-2020 Belledonne Communications SARL.
*
* This file is part of linphone-iphone
*
* This program is free software: you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation, either version 3 of the License, or
* (at your option) any later version.
*
* This program is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU General Public License for more details.
*
* You should have received a copy of the GNU General Public License
* along with this program. If not, see <http://www.gnu.org/licenses/>.
*/

import Foundation
import linphonesw
import UserNotifications
import os
import CallKit
import AVFoundation

@objc class CallAppData: NSObject {
	@objc var batteryWarningShown = false
	@objc var videoRequested = false /*set when user has requested for video*/
	@objc var isConference = true

}

/*
* CallManager is a class that manages application calls and supports callkit.
* There is only one CallManager by calling CallManager.instance().
*/
@objc class CallManager: NSObject, CoreDelegate {
	static var theCallManager: CallManager?
	let providerDelegate: ProviderDelegate! // to support callkit
	let callController: CXCallController! // to support callkit
	var core: Core?
	@objc var nextCallIsTransfer: Bool = false
	var referedFromCall: String?
	var referedToCall: String?
	var endCallkit: Bool = false
	var globalState : GlobalState = .Off
	var actionsToPerformOnceWhenCoreIsOn : [(()->Void)] = []

	
	
	var backgroundContextCall : Call?
	@objc var backgroundContextCameraIsEnabled : Bool = false

	fileprivate override init() {
		providerDelegate = ProviderDelegate.shared
		callController = CXCallController()
	}

	@objc static func instance() -> CallManager {
		if (theCallManager == nil) {
			theCallManager = CallManager()
		}
		return theCallManager!
	}


	@objc func setCore(core: OpaquePointer) {
		self.core = Core.getSwiftObject(cObject: core)
		self.core?.addDelegate(delegate: self)
	}

	@objc static func getAppData(call: OpaquePointer) -> CallAppData? {
		let sCall = Call.getSwiftObject(cObject: call)
		return getAppData(sCall: sCall)
	}
	
	static func getAppData(sCall:Call) -> CallAppData? {
		if (sCall.userData == nil) {
			return nil
		}
		return Unmanaged<CallAppData>.fromOpaque(sCall.userData!).takeUnretainedValue()
	}

	@objc static func setAppData(call:OpaquePointer, appData: CallAppData) {
		let sCall = Call.getSwiftObject(cObject: call)
		setAppData(sCall: sCall, appData: appData)
	}
	
	static func setAppData(sCall:Call, appData:CallAppData?) {
		if (sCall.userData != nil) {
			Unmanaged<CallAppData>.fromOpaque(sCall.userData!).release()
		}
		if (appData == nil) {
			sCall.userData = nil
		} else {
			sCall.userData = UnsafeMutableRawPointer(Unmanaged.passRetained(appData!).toOpaque())
		}
	}

	@objc func findCall(callId: String?) -> OpaquePointer? {
		let call = callByCallId(callId: callId)
		return call?.getCobject
	}

	func callByCallId(callId: String?) -> Call? {
		if (callId == nil) {
			return nil
		}
		let calls = core?.calls
		if let callTmp = calls?.first(where: { $0.callLog?.callId == callId }) {
			return callTmp
		}
		return nil
	}

	@objc func stopLinphoneCore() {
		if (core?.callsNb == 0) {
			core?.stopAsync()
		}
	}
	
	@objc func getBackgroundContextCall() -> OpaquePointer? {
		return backgroundContextCall?.getCobject
	}
	@objc func setBackgroundContextCall(call: OpaquePointer?) {
		if (call == nil) {
			backgroundContextCall = nil
		} else {
			backgroundContextCall = Call.getSwiftObject(cObject: call!)
		}
	}
	
	@objc static func callKitEnabled() -> Bool {
		#if !targetEnvironment(simulator)
		if ConfigManager.instance().lpConfigBoolForKey(key: "use_callkit", section: "app") {
			return true
		}
		#endif
		return false
	}
	
	
	func requestTransaction(_ transaction: CXTransaction, action: String) {
		callController.request(transaction) { error in
			if let error = error {
				Log.directLog(BCTBX_LOG_ERROR, text: "CallKit: Requested transaction \(action) failed because: \(error)")
			} else {
				Log.directLog(BCTBX_LOG_MESSAGE, text: "CallKit: Requested transaction \(action) successfully")
			}
		}
	}
	
	@objc func updateCallId(previous: String, current: String) {
		let uuid = CallManager.instance().providerDelegate.uuids["\(previous)"]
		if (uuid != nil) {
			CallManager.instance().providerDelegate.uuids.removeValue(forKey: previous)
			CallManager.instance().providerDelegate.uuids.updateValue(uuid!, forKey: current)
			let callInfo = providerDelegate.callInfos[uuid!]
			if (callInfo != nil) {
				callInfo!.callId = current
				providerDelegate.callInfos.updateValue(callInfo!, forKey: uuid!)
			}
		}
	}

	func displayIncomingCall(call:Call?, handle: String, hasVideo: Bool, callId: String, displayName:String) {
		let uuid = UUID()
		let callInfo = CallInfo.newIncomingCallInfo(callId: callId)

		providerDelegate.callInfos.updateValue(callInfo, forKey: uuid)
		providerDelegate.uuids.updateValue(uuid, forKey: callId)
		providerDelegate.reportIncomingCall(call:call, uuid: uuid, handle: handle, hasVideo: hasVideo, displayName: displayName)
		
	}

	@objc func acceptCall(call: OpaquePointer?, hasVideo:Bool) {
		if (call == nil) {
			Log.directLog(BCTBX_LOG_ERROR, text: "Can not accept null call!")
			return
		}
		let call = Call.getSwiftObject(cObject: call!)
		acceptCall(call: call, hasVideo: hasVideo)
	}

	func acceptCall(call: Call, hasVideo:Bool) {
		do {
			let callParams = try core!.createCallParams(call: call)
			callParams.videoEnabled = hasVideo
			if (ConfigManager.instance().lpConfigBoolForKey(key: "edge_opt_preference")) {
				let low_bandwidth = (AppManager.network() == .network_2g)
				if (low_bandwidth) {
					Log.directLog(BCTBX_LOG_MESSAGE, text: "Low bandwidth mode")
				}
				callParams.lowBandwidthEnabled = low_bandwidth
			}

			//We set the record file name here because we can't do it after the call is started.
			let address = call.callLog?.fromAddress
			let writablePath = AppManager.recordingFilePathFromCall(address: address?.username ?? "")
			Log.directLog(BCTBX_LOG_MESSAGE, text: "Record file path: \(String(describing: writablePath))")
			callParams.recordFile = writablePath
			
			
			if let chatView : ChatConversationView = PhoneMainView.instance().VIEW(ChatConversationView.compositeViewDescription()), chatView.isVoiceRecording {
				Log.directLog(BCTBX_LOG_MESSAGE, text: "Voice recording in progress, stopping it befoce accepting the call.")
				chatView.stopVoiceRecording()
			}
			
			if (call.callLog?.wasConference() == true) {
				// Prevent incoming group call to start in audio only layout
				// Do the same as the conference waiting room
				callParams.videoEnabled = true
				callParams.videoDirection = Core.get().videoActivationPolicy?.automaticallyInitiate == true ?  .SendRecv : .RecvOnly
				Log.i("[Context] Enabling video on call params to prevent audio-only layout when answering")
			}
			
			try call.acceptWithParams(params: callParams)
		} catch {
			Log.directLog(BCTBX_LOG_ERROR, text: "accept call failed \(error)")
		}
	}

	// for outgoing call. There is not yet callId
	@objc func startCall(addr: OpaquePointer?, isSas: Bool, isVideo: Bool, isConference: Bool = false) {
		if (addr == nil) {
			print("Can not start a call with null address!")
			return
		}

		let sAddr = Address.getSwiftObject(cObject: addr!)
		if (CallManager.callKitEnabled() && !CallManager.instance().nextCallIsTransfer && core?.conference?.isIn != true) {
			let uuid = UUID()
			let name = FastAddressBook.displayName(for: addr) ?? "unknow"
			let handle = CXHandle(type: .generic, value: sAddr.asStringUriOnly())
			let startCallAction = CXStartCallAction(call: uuid, handle: handle)
			let transaction = CXTransaction(action: startCallAction)

			let callInfo = CallInfo.newOutgoingCallInfo(addr: sAddr, isSas: isSas, displayName: name, isVideo: isVideo, isConference:isConference)
			providerDelegate.callInfos.updateValue(callInfo, forKey: uuid)
			providerDelegate.uuids.updateValue(uuid, forKey: "")

			setHeldOtherCalls(exceptCallid: "")
			requestTransaction(transaction, action: "startCall")
		}else {
			try? doCall(addr: sAddr, isSas: isSas, isVideo:isVideo, isConference:isConference)
		}
	}
	
	func startCall(addr:String, isSas: Bool = false, isVideo: Bool, isConference: Bool = false) {
		do {
		 let address = try Factory.Instance.createAddress(addr: addr)
			startCall(addr: address.getCobject,isSas: isSas, isVideo: isVideo, isConference:isConference)
		} catch {
			Log.e("[CallManager] unable to create address for a new outgoing call : \(addr) \(error) ")
		}
	}

	func doCall(addr: Address, isSas: Bool, isVideo: Bool, isConference:Bool = false) throws {
		let displayName = FastAddressBook.displayName(for: addr.getCobject)

		let lcallParams = try CallManager.instance().core!.createCallParams(call: nil)
		if ConfigManager.instance().lpConfigBoolForKey(key: "edge_opt_preference") && AppManager.network() == .network_2g {
			Log.directLog(BCTBX_LOG_MESSAGE, text: "Enabling low bandwidth mode")
			lcallParams.lowBandwidthEnabled = true
		}

		if (displayName != nil) {
			try addr.setDisplayname(newValue: displayName!)
		}

		if(ConfigManager.instance().lpConfigBoolForKey(key: "override_domain_with_default_one")) {
			try addr.setDomain(newValue: ConfigManager.instance().lpConfigStringForKey(key: "domain", section: "assistant"))
		}

		if (CallManager.instance().nextCallIsTransfer) {
			let call = CallManager.instance().core!.currentCall
			try call?.transferTo(referTo: addr)
			CallManager.instance().nextCallIsTransfer = false
		} else {
			//We set the record file name here because we can't do it after the call is started.
			let writablePath = AppManager.recordingFilePathFromCall(address: addr.username )
			Log.directLog(BCTBX_LOG_DEBUG, text: "record file path: \(writablePath)")
			lcallParams.recordFile = writablePath
			if (isSas) {
				lcallParams.mediaEncryption = .ZRTP
			}
			if (isConference) {
				lcallParams.videoEnabled = true
				lcallParams.videoDirection = ConferenceWaitingRoomViewModel.sharedModel.isVideoEnabled.value == true ? .SendRecv : .RecvOnly
				lcallParams.conferenceVideoLayout = ConferenceWaitingRoomViewModel.sharedModel.joinLayout.value!
			} else {
				lcallParams.videoEnabled = isVideo
			}
			
			let call = CallManager.instance().core!.inviteAddressWithParams(addr: addr, params: lcallParams)
			if (call != nil) {
				// The LinphoneCallAppData object should be set on call creation with callback
				// - (void)onCall:StateChanged:withMessage:. If not, we are in big trouble and expect it to crash
				// We are NOT responsible for creating the AppData.
				let data = CallManager.getAppData(sCall: call!)
				if (data == nil) {
					Log.directLog(BCTBX_LOG_ERROR, text: "New call instanciated but app data was not set. Expect it to crash.")
					/* will be used later to notify user if video was not activated because of the linphone core*/
				} else {
					data!.isConference = isConference
					data!.videoRequested = lcallParams.videoEnabled
					CallManager.setAppData(sCall: call!, appData: data)
				}
			}
		}
	}

	@objc func removeAllCallInfos() {
		providerDelegate.callInfos.removeAll()
		providerDelegate.uuids.removeAll()
	}

	@objc func terminateCall(call: OpaquePointer?) {
		if (call == nil) {
			Log.directLog(BCTBX_LOG_ERROR, text: "Can not terminate null call!")
			return
		}
		let call = Call.getSwiftObject(cObject: call!)
		do {
			try call.terminate()
			Log.directLog(BCTBX_LOG_DEBUG, text: "Call terminated")
		} catch {
			Log.directLog(BCTBX_LOG_ERROR, text: "Failed to terminate call failed because \(error)")
		}
	}

	@objc func markCallAsDeclined(callId: String) {
		if !CallManager.callKitEnabled() {
			return
		}

		let uuid = providerDelegate.uuids["\(callId)"]
		if (uuid == nil) {
			Log.directLog(BCTBX_LOG_MESSAGE, text: "Mark call \(callId) as declined.")
			let uuid = UUID()
			providerDelegate.uuids.updateValue(uuid, forKey: callId)
			let callInfo = CallInfo.newIncomingCallInfo(callId: callId)
			callInfo.reason = Reason.Busy
			providerDelegate.callInfos.updateValue(callInfo, forKey: uuid)
		} else {
			// end call
			providerDelegate.endCall(uuid: uuid!)
		}
	}

	@objc func setHeld(call: OpaquePointer, hold: Bool) {
		let sCall = Call.getSwiftObject(cObject: call)
		if (!hold) {
			setHeldOtherCalls(exceptCallid: sCall.callLog?.callId ?? "")
		}
		setHeld(call: sCall, hold: hold)
	}
	
	func setHeld(call: Call, hold: Bool) {
		
		#if targetEnvironment(simulator)
		if (hold) {
			try?call.pause()
		} else {
			try?call.resume()
		}
		#else
		let callid = call.callLog?.callId ?? ""
		let uuid = providerDelegate.uuids["\(callid)"]
		if (uuid == nil) {
			Log.directLog(BCTBX_LOG_ERROR, text: "Can not find correspondant call to set held.")
			return
		}
		let setHeldAction = CXSetHeldCallAction(call: uuid!, onHold: hold)
		let transaction = CXTransaction(action: setHeldAction)
		requestTransaction(transaction, action: "setHeld")
		#endif
	}

	@objc func setHeldOtherCalls(exceptCallid: String) {
		for call in CallManager.instance().core!.calls {
			if (call.callLog?.callId != exceptCallid && call.state != .Paused && call.state != .Pausing && call.state != .PausedByRemote) {
				setHeld(call: call, hold: true)
			}
		}
	}

	func setResumeCalls() {
		for call in CallManager.instance().core!.calls {
			if (call.state == .Paused || call.state == .Pausing || call.state == .PausedByRemote) {
				setHeld(call: call, hold: false)
			}
		}
	}

	@objc func performActionWhenCoreIsOn(action:  @escaping ()->Void ) {
		if (globalState == .On) {
			action()
		} else {
			actionsToPerformOnceWhenCoreIsOn.append(action)
		}
	}

	@objc func acceptVideo(call: OpaquePointer, confirm: Bool) {
		let sCall = Call.getSwiftObject(cObject: call)
		let params = try? core?.createCallParams(call: sCall)
		params?.videoEnabled = confirm
		try? sCall.acceptUpdate(params: params)
	}

	func onGlobalStateChanged(core: Core, state: GlobalState, message: String) {
		if (state == .On) {
			actionsToPerformOnceWhenCoreIsOn.forEach {
				$0()
			}
			actionsToPerformOnceWhenCoreIsOn.removeAll()
		}
		globalState = state
	}

	func onRegistrationStateChanged(core: Core, proxyConfig: ProxyConfig, state: RegistrationState, message: String) {
		if core.proxyConfigList.count == 1 && (state == .Failed || state == .Cleared){
			// terminate callkit immediately when registration failed or cleared, supporting single proxy configuration
			for call in CallManager.instance().providerDelegate.uuids {
				let callId = CallManager.instance().providerDelegate.callInfos[call.value]?.callId
				if (callId != nil) {
					let call = CallManager.instance().core?.getCallByCallid(callId: callId!)
					if (call != nil && call?.state != .PushIncomingReceived) {
						// sometimes (for example) due to network, registration failed, in this case, keep the call
						continue
					}
				}

				CallManager.instance().providerDelegate.endCall(uuid: call.value)
			}
			CallManager.instance().endCallkit = true
		} else {
			CallManager.instance().endCallkit = false
		}
	}
	
	func isConferenceCall(call:Call) -> Bool {
		let remoteAddress = call.remoteAddress?.asStringUriOnly()
		return remoteAddress?.contains("focus") == true || remoteAddress?.contains("audiovideo") == true
	}

	func onCallStateChanged(core: Core, call: Call, state cstate: Call.State, message: String) {
		let callLog = call.callLog
		let callId = callLog?.callId
		if (cstate == .PushIncomingReceived) {
			displayIncomingCall(call: call, handle: "Calling", hasVideo: false, callId: callId!, displayName: "Calling")
		} else {
			let video = (core.videoActivationPolicy?.automaticallyAccept ?? false) && (call.remoteParams?.videoEnabled ?? false)

			if (call.userData == nil) {
				let appData = CallAppData()
				CallManager.setAppData(sCall: call, appData: appData)
			}
			
			if let conference = call.conference, ConferenceViewModel.shared.conference.value == nil {
				Log.i("[Call] Found conference attached to call and no conference in dedicated view model, init & configure it")
				ConferenceViewModel.shared.initConference(conference)
				ConferenceViewModel.shared.configureConference(conference)
			}

			switch cstate {
				case .IncomingReceived:
					let addr = call.remoteAddress
					var displayName = ""
					let isConference = isConferenceCall(call: call)
					let isEarlyConference = isConference && CallsViewModel.shared.currentCallData.value??.isConferenceCall.value != true // Conference info not be received yet.
					if (isConference) {
						if (isEarlyConference) {
							displayName = VoipTexts.conference_incoming_title
						} else {
							displayName = "\(VoipTexts.conference_incoming_title):  \(CallsViewModel.shared.currentCallData.value??.remoteConferenceSubject.value ?? "") (\(CallsViewModel.shared.currentCallData.value??.conferenceParticipantsCountLabel.value ?? ""))"
						}
					} else {
						displayName = FastAddressBook.displayName(for: addr?.getCobject) ?? "Unknown"
					}
				
					if (CallManager.callKitEnabled()) {
						if (isEarlyConference) {
							CallsViewModel.shared.currentCallData.readCurrentAndObserve { _ in
								let uuid = CallManager.instance().providerDelegate.uuids["\(callId!)"]
								if (uuid != nil) {
									displayName = "\(VoipTexts.conference_incoming_title):  \(CallsViewModel.shared.currentCallData.value??.remoteConferenceSubject.value ?? "") (\(CallsViewModel.shared.currentCallData.value??.conferenceParticipantsCountLabel.value ?? ""))"
									CallManager.instance().providerDelegate.updateCall(uuid: uuid!, handle: addr!.asStringUriOnly(), hasVideo: video, displayName: displayName)
								}
							}
						}
						
						let uuid = CallManager.instance().providerDelegate.uuids["\(callId!)"]
						if (uuid != nil) {
							// Tha app is now registered, updated the call already existed.
							CallManager.instance().providerDelegate.updateCall(uuid: uuid!, handle: addr!.asStringUriOnly(), hasVideo: video, displayName: displayName)
						} else {
							CallManager.instance().displayIncomingCall(call: call, handle: addr!.asStringUriOnly(), hasVideo: video, callId: callId!, displayName: displayName)
						}
					} else if (UIApplication.shared.applicationState != .active) {
						// not support callkit , use notif
						let content = UNMutableNotificationContent()
						content.title = NSLocalizedString("Incoming call", comment: "")
						content.body = displayName
						content.sound = UNNotificationSound.init(named: UNNotificationSoundName.init("notes_of_the_optimistic.caf"))
						content.categoryIdentifier = "call_cat"
						content.userInfo = ["CallId" : callId!]
						let req = UNNotificationRequest.init(identifier: "call_request", content: content, trigger: nil)
							UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
					}
					break
				case .StreamsRunning:
					if (CallManager.callKitEnabled()) {
						let uuid = CallManager.instance().providerDelegate.uuids["\(callId!)"]
						if (uuid != nil) {
							let callInfo = CallManager.instance().providerDelegate.callInfos[uuid!]
							if (callInfo != nil && callInfo!.isOutgoing && !callInfo!.connected) {
								Log.directLog(BCTBX_LOG_MESSAGE, text: "CallKit: outgoing call connected with uuid \(uuid!) and callId \(callId!)")
								CallManager.instance().providerDelegate.reportOutgoingCallConnected(uuid: uuid!)
								callInfo!.connected = true
								CallManager.instance().providerDelegate.callInfos.updateValue(callInfo!, forKey: uuid!)
							}
						}
					}
					break
				case .OutgoingInit,
					 .OutgoingProgress,
					 .OutgoingRinging,
					 .OutgoingEarlyMedia:
					if (CallManager.callKitEnabled()) {
						let uuid = CallManager.instance().providerDelegate.uuids[""]
						if (uuid != nil) {
							let callInfo = CallManager.instance().providerDelegate.callInfos[uuid!]
							callInfo!.callId = callId!
							CallManager.instance().providerDelegate.callInfos.updateValue(callInfo!, forKey: uuid!)
							CallManager.instance().providerDelegate.uuids.removeValue(forKey: "")
							CallManager.instance().providerDelegate.uuids.updateValue(uuid!, forKey: callId!)

							Log.directLog(BCTBX_LOG_MESSAGE, text: "CallKit: outgoing call started connecting with uuid \(uuid!) and callId \(callId!)")
							CallManager.instance().providerDelegate.reportOutgoingCallStartedConnecting(uuid: uuid!)
						} else {
							CallManager.instance().referedToCall = callId
						}
					}
					break
				case .End,
					 .Error:
					var displayName = "Unknown"
					if let addr = call.remoteAddress, let contactName = FastAddressBook.displayName(for: addr.getCobject) {
						displayName = contactName
					}
					

					if UIApplication.shared.applicationState != .active && (callLog == nil || callLog?.status == .Missed || callLog?.status == .Aborted || callLog?.status == .EarlyAborted)  {
						// Configure the notification's payload.
						let content = UNMutableNotificationContent()
						content.title = NSString.localizedUserNotificationString(forKey: NSLocalizedString("Missed call", comment: ""), arguments: nil)
						content.body = NSString.localizedUserNotificationString(forKey: displayName, arguments: nil)

						// Deliver the notification.
						let request = UNNotificationRequest(identifier: "call_request", content: content, trigger: nil) // Schedule the notification.
						let center = UNUserNotificationCenter.current()
						center.add(request) { (error : Error?) in
							if error != nil {
							Log.directLog(BCTBX_LOG_ERROR, text: "Error while adding notification request : \(error!.localizedDescription)")
							}
						}
					}

					if (CallManager.callKitEnabled()) {
						var uuid = CallManager.instance().providerDelegate.uuids["\(callId!)"]
						if (callId == CallManager.instance().referedToCall) {
							// refered call ended before connecting
							Log.directLog(BCTBX_LOG_MESSAGE, text: "Callkit: end refered to call :  \(String(describing: CallManager.instance().referedToCall))")
							CallManager.instance().referedFromCall = nil
							CallManager.instance().referedToCall = nil
						}
						if uuid == nil {
							// the call not yet connected
							uuid = CallManager.instance().providerDelegate.uuids[""]
						}
						if (uuid != nil) {
							if (callId == CallManager.instance().referedFromCall) {
								Log.directLog(BCTBX_LOG_MESSAGE, text: "Callkit: end refered from call : \(String(describing: CallManager.instance().referedFromCall))")
								CallManager.instance().referedFromCall = nil
								let callInfo = CallManager.instance().providerDelegate.callInfos[uuid!]
								callInfo!.callId = CallManager.instance().referedToCall ?? ""
								CallManager.instance().providerDelegate.callInfos.updateValue(callInfo!, forKey: uuid!)
								CallManager.instance().providerDelegate.uuids.removeValue(forKey: callId!)
								CallManager.instance().providerDelegate.uuids.updateValue(uuid!, forKey: callInfo!.callId)
								CallManager.instance().referedToCall = nil
								break
							}

							let transaction = CXTransaction(action:
							CXEndCallAction(call: uuid!))
							CallManager.instance().requestTransaction(transaction, action: "endCall")
						}
					}
					break
				case .Released:
					call.userData = nil
					break
				case .Referred:
					CallManager.instance().referedFromCall = call.callLog?.callId
					break
				default:
					break
			}

		}
		// post Notification kLinphoneCallUpdate
		NotificationCenter.default.post(name: Notification.Name("LinphoneCallUpdate"), object: self, userInfo: [
			AnyHashable("call"): NSValue.init(pointer:UnsafeRawPointer(call.getCobject)),
			AnyHashable("state"): NSNumber(value: cstate.rawValue),
			AnyHashable("message"): message
		])
	}

	// Audio messages
	
	@objc func activateAudioSession() {
		core?.activateAudioSession(actived: true)
	}
	
	@objc func getSpeakerSoundCard() -> String? {
		var speakerCard: String? = nil
		var earpieceCard: String? = nil
		core?.audioDevices.forEach { device in
			if (device.hasCapability(capability: .CapabilityPlay)) {
				if (device.type == .Speaker) {
					speakerCard = device.id
				} else if (device.type == .Earpiece) {
					earpieceCard = device.id
				}
			}
		}
		return speakerCard != nil ? speakerCard : earpieceCard
	}

	// Local Conference
	
	@objc func startLocalConference() {
		if (CallManager.callKitEnabled()) {
			let calls = core?.calls
			if (calls == nil || calls!.isEmpty) {
				return
			}
			let firstCall = calls!.first?.callLog?.callId ?? ""
			let lastCall = (calls!.count > 1) ? calls!.last?.callLog?.callId ?? "" : ""

			let currentUuid = CallManager.instance().providerDelegate.uuids["\(firstCall)"]
			if (currentUuid == nil) {
				Log.directLog(BCTBX_LOG_ERROR, text: "Can not find correspondant call to group.")
				return
			}

			let newUuid = CallManager.instance().providerDelegate.uuids["\(lastCall)"]
			let groupAction = CXSetGroupCallAction(call: currentUuid!, callUUIDToGroupWith: newUuid)
			let transcation = CXTransaction(action: groupAction)
			requestTransaction(transcation, action: "groupCall")

			setResumeCalls()
		} else {
			addAllToLocalConference()
		}
	}
	
	func addAllToLocalConference() {
		do {
			if let core = core, let params = try? core.createConferenceParams(conference: nil) {
				params.videoEnabled = false // We disable video for local conferencing (cf Android)
				let conference = core.conference != nil ? core.conference : try core.createConferenceWithParams(params: params)
				try conference?.addParticipants(calls: core.calls)
			}
		} catch {
			Log.directLog(BCTBX_LOG_ERROR, text: "accept call failed \(error)")
		}
	}
	
	
	
}



/**
 * @file AppBridge.js
 * @description 生产级 JSBridge Web 端实现，支持 Promise 事务、超时、错误处理和事件监听。
 *              该脚本会在 WebView 加载时注入，提供 window.AppBridge 对象供 Web 应用调用 Native 功能。
 */

(function() {
    if (window.AppBridge) {
        console.warn('AppBridge already exists, skipping re-initialization.');
        return;
    }

    const NATIVE_BRIDGE_NAME = 'JSBridge'; // 与 Native 侧 WKScriptMessageHandler 的 name 保持一致
    const TIMEOUT_MS = 15000; // 15秒超时

    let callbackIdCounter = 0;
    const callbacks = new Map(); // 存储 Promise 的 resolve/reject 函数
    const eventListeners = new Map(); // 存储 Web 侧注册的事件监听器

    /**
     * 生成唯一的 callbackId
     * @returns {string}
     */
    function generateCallbackId() {
        return `cb_${Date.now()}_${callbackIdCounter++}`;
    }

    /**
     * Web 调用 Native 方法
     * @param {string} action - Native 侧的方法名
     * @param {object} [payload={}] - 传递给 Native 的参数
     * @returns {Promise<any>}
     */
    function call(action, payload = {}) {
        return new Promise((resolve, reject) => {
            const callbackId = generateCallbackId();

            // 存储回调函数
            callbacks.set(callbackId, { resolve, reject });

            // 设置超时
            const timeout = setTimeout(() => {
                if (callbacks.has(callbackId)) {
                    callbacks.delete(callbackId);
                    reject(new Error(`JSBridge Timeout: Native action '${action}' timed out after ${TIMEOUT_MS / 1000}s.`));
                }
            }, TIMEOUT_MS);

            // 准备发送给 Native 的消息
            const message = {
                action: action,
                params: payload,
                callbackId: callbackId
            };

            // 发送消息给 Native
            try {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[NATIVE_BRIDGE_NAME]) {
                    window.webkit.messageHandlers[NATIVE_BRIDGE_NAME].postMessage(message);
                } else {
                    console.error('JSBridge: Native message handler not found.');
                    callbacks.delete(callbackId);
                    clearTimeout(timeout);
                    reject(new Error('JSBridge Error: Native environment not ready or message handler not found.'));
                }
            } catch (e) {
                console.error('JSBridge: Error posting message to Native:', e);
                callbacks.delete(callbackId);
                clearTimeout(timeout);
                reject(new Error(`JSBridge Error: Failed to post message to Native: ${e.message}`));
            }
        });
    }

    /**
     * 处理 Native 返回的响应
     * @param {object} response - Native 返回的响应对象
     */
    function handleResponse(response) {
        const { callbackId, success, data, error } = response;

        if (!callbackId || !callbacks.has(callbackId)) {
            console.warn('JSBridge: Received response for unknown or expired callbackId:', callbackId, response);
            return;
        }

        const { resolve, reject } = callbacks.get(callbackId);
        callbacks.delete(callbackId); // 移除回调

        if (success) {
            resolve(data);
        } else {
            const err = new Error(error?.message || 'Unknown Native Error');
            err.code = error?.code || 'NATIVE_ERROR';
            reject(err);
        }
    }

    /**
     * 注册事件监听器
     * @param {string} eventName - 事件名称
     * @param {Function} listener - 事件回调函数
     */
    function on(eventName, listener) {
        if (!eventListeners.has(eventName)) {
            eventListeners.set(eventName, new Set());
        }
        eventListeners.get(eventName).add(listener);
    }

    /**
     * 移除事件监听器
     * @param {string} eventName - 事件名称
     * @param {Function} listener - 要移除的事件回调函数
     */
    function off(eventName, listener) {
        if (eventListeners.has(eventName)) {
            eventListeners.get(eventName).delete(listener);
            if (eventListeners.get(eventName).size === 0) {
                eventListeners.delete(eventName);
            }
        }
    }

    /**
     * Native 主动触发 Web 事件
     * @param {string} eventName - 事件名称
     * @param {object} [data={}] - 传递给 Web 的数据
     */
    function dispatchEvent(eventName, data = {}) {
        if (eventListeners.has(eventName)) {
            eventListeners.get(eventName).forEach(listener => {
                try {
                    listener(data);
                } catch (e) {
                    console.error(`JSBridge: Error in event listener for '${eventName}':`, e);
                }
            });
        }
    }

    // 将 AppBridge 暴露到 window 对象
    window.AppBridge = {
        call: call,
        handleResponse: handleResponse, // 供 Native 调用
        on: on,
        off: off,
        dispatchEvent: dispatchEvent // 供 Native 调用
    };

    console.log('AppBridge initialized successfully.');

    // 触发一个事件通知 Web 端 AppBridge 已就绪
    window.dispatchEvent(new CustomEvent('AppBridgeReady'));
})();

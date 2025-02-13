/**
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

// defines window.requirejs
// $FlowFixMe[cannot-resolve-module]
import './require_2_3_3';

declare function requirejs(pathList: $ReadOnlyArray<string>, resolve: (any) => void): void;

const versionCache /*: Map<string, Promise<FlowJs>> */ = new Map();

const TRY_LIB_CONTENTS = `
declare type $JSXIntrinsics = {
  [string]: {
    instance: any,
    props: {
      children?: React$Node,
      [key: string]: any,
    },
  },
};
`.slice(1);

function get(url: string) {
  return new Promise<[string, string]>((resolve, reject) => {
    const req = new XMLHttpRequest();
    req.timeout = 5000;
    req.onload = () => {
      if (req.status === 200) {
        resolve([url, req.response]);
      } else {
        reject(Error(req.statusText));
      }
    };
    req.onerror = () => {
      reject("Network error");
    };
    req.ontimeout = () => {
      reject("Network timed out");
    };
    req.onabort = () => {
      reject("Network request aborted");
    };
    req.open('GET', url);
    req.send();
  });
}

export function load(withBaseUrl: string => string, version: string): Promise<FlowJs> {
  const cached = versionCache.get(version);
  if (cached) {
    return Promise.resolve(cached);
  }
  const majorVersion =
    version === 'master'
    ? Infinity
    : parseInt(version.split('.')[1], 10);
  const libs = (majorVersion <= 54 ? [
    `/flow/${version}/flowlib/core.js`,
    `/flow/${version}/flowlib/bom.js`,
    `/flow/${version}/flowlib/cssom.js`,
    `/flow/${version}/flowlib/dom.js`,
    `/flow/${version}/flowlib/node.js`,
    `/flow/${version}/flowlib/react.js`,
    `/flow/${version}/flowlib/streams.js`,
  ] : majorVersion <= 71 ? [
    `/flow/${version}/flowlib/core.js`,
    `/flow/${version}/flowlib/react.js`,
  ] : [
    `/flow/${version}/flowlib/core.js`,
    `/flow/${version}/flowlib/react.js`,
    `/flow/${version}/flowlib/intl.js`,
  ]).map(withBaseUrl);
  const flowLoader = new Promise<[string, string]>(resolve => {
      requirejs([withBaseUrl(`/flow/${version}/flow.js`)], resolve);
  });
  return Promise.all([flowLoader, ...libs.map(get)])
    .then(([_flow, ...contents]) => {
      contents.forEach(nameAndContent => {
        self.flow.registerFile(nameAndContent[0], nameAndContent[1]);
      });
      self.flow.registerFile('try-lib.js', TRY_LIB_CONTENTS);
      if (majorVersion <= 126) {
        self.flow.setLibs([...libs, 'try-lib.js']);
      } else {
        self.flow.initBuiltins([...libs, 'try-lib.js']);
      }
      versionCache.set(version, self.flow);
      // $FlowFixMe[cannot-resolve-name]
      return flow;
    });
}

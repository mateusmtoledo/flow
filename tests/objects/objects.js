/* @flow */

var x : {'123': string, bar: string} = {'123': 'val', bar: 'bar'};
(x.foo : string);     // error, key doesn't exist
(x['foo'] : string);  // error, key doesn't exist
(x[123] : boolean);   // TODO: use the number's value to error here
(x.bar: boolean);     // error, string !~> boolean
(x['123'] : boolean); // error, string !~> boolean
x['123'] = false;     // error, boolean !~> string
x[123] = false;       // error: no indexed type
x['foo'+'bar'] = 'derp'; // error: no indexed type
(x[`foo`]: string);   // error, key doesn't exist

var y : {foo: string} = {foo: 'bar'};
y['foo'] = 123; // error, number !~> string
y['bar'] = 'abc'; // error, property not found

(y['hasOwnProperty']: string); // error, prototype method is not a string

// ok because properties named 'constructor' are only banned on classes
var has_constructor_field : {constructor: string} = {constructor: 'foo'}

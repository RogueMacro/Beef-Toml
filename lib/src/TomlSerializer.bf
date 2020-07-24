using System;
using System.Collections;
using JetFistGames.Toml.Internal;
using System.IO;
using System.Reflection;

namespace JetFistGames.Toml
{
	public sealed class TomlSerializer
	{
		public static Result<TomlNode,TomlError> Read(StringView input)
		{
			let parser = new Parser(scope String(input));
			let result = parser.Parse();

			delete parser;

			switch(result)
			{
			case .Ok(let val):
				return .Ok(val);
			case .Err(let err):
				return .Err(err);
			}
		}

		public static Result<void, TomlError> ReadFile(StringView path, Object dest)
		{
			var file = scope String();
			let fileReadResult = File.ReadAllText(path, file);

			if (fileReadResult case .Err(let err))
			{
				var filename = scope String();
				Path.GetFileName(path, filename);
				return .Err(.(-1, "Could not read file '{}': {}", filename, err));
			}

			return Read(file, dest);
		}

		public static Result<void, TomlError> Read(StringView input, Object dest)
		{
			let result = Read(input);

			if (result case .Err(let err))
				return .Err(err);

			let doc = (TomlTableNode) result.Get();
			return Read(doc, dest);
		}

		public static Result<void, TomlError> Read(TomlTableNode doc, Object dest, bool deleteDoc = true)
		{
			var dataMembers = GetDataMembers(dest.GetType());

			for (let key in doc.Keys)
			{
				FieldLoop: for (let dataMember in dataMembers)
				{
					if (dataMember.Name != key)
						continue;

					if (IsMatchingType(doc[key].Kind, dataMember.FieldInfo.FieldType))
					{
						switch (doc[key].Kind)
						{
						case .String:
							dataMember.FieldInfo.SetValue(dest, new String(doc[key].GetString().Get()));
							break FieldLoop;
						case .Int:
							dataMember.FieldInfo.SetValue(dest, doc[key].GetInt().Get());
							break FieldLoop;
						case .Float:
							dataMember.FieldInfo.SetValue(dest, doc[key].GetFloat().Get());
							break FieldLoop;
						case .Bool:
							dataMember.FieldInfo.SetValue(dest, doc[key].GetBool().Get());
							break FieldLoop;
						case .Table:
							dataMember.FieldInfo.SetValue(dest, doc[key].GetTable().Get().ToObject());
							break FieldLoop;
						case .Array:
							dataMember.FieldInfo.SetValue(dest, doc[key].GetArray().Get().ToObject());
							break FieldLoop;
						case .Datetime:
							dataMember.FieldInfo.SetValue(dest, doc[key].GetDatetime().Get());
							break FieldLoop;
						}
					}
					else if (doc[key].Kind == .Table)
					{
						var value = dataMember.FieldInfo.FieldType.CreateObject().Get();

						let table = (TomlTableNode) doc[key];
						if (Read(table, value, false) case .Err(let err))
							return .Err(err);

						dataMember.FieldInfo.SetValue(dest, value);
					}
				}
			}

			DeleteContainerAndItems!(dataMembers);

			if (deleteDoc)
				delete doc;

			return .Ok;
			
			bool IsMatchingType(TomlValueType valueType, Type fieldType)
			{
				if ((valueType == .String   && fieldType == typeof(String))                     ||
				    (valueType == .Int      && fieldType == typeof(int))                        ||
				    (valueType == .Float    && fieldType == typeof(float))                      ||
				    (valueType == .Bool     && fieldType == typeof(bool))                       ||
				    (valueType == .Table    && fieldType == typeof(Dictionary<String, Object>)) ||
				    (valueType == .Array    && fieldType == typeof(List<Object>))               ||
				    (valueType == .Datetime && fieldType == typeof(DateTime)))
						return true;

				return false;
			}
		}

		public static void WriteFile(Object object, StringView path)
		{
			var str = scope String();
			Write(object, str);
			File.WriteAllText(path, str);
		}

		public static void Write(Object object, String output)
		{
			//var dataMembers = GetDataMembers(typeof(T));
		}

		public static void Write(TomlTableNode root, String output)
		{
			output.Clear();

			let arrayKeys = scope List<StringView>();
			let tableKeys = scope List<StringView>();

			// first, we need to write any root-level atomic values, skipping arrays and tables
			for(var key in root.Keys)
			{
				var node = root[key];

				if(node.Kind == .Array)
				{
					arrayKeys.Add(key);
				}
				else if(node.Kind == .Table)
				{
					tableKeys.Add(key);
				}
				else
				{
					output.AppendF("{0} = ", key);
					Emit(node, output);
					output.Append("\n");
				}
			}

			output.Append("\n");

			// now let's write arrays
			for(var key in arrayKeys)
			{
				output.AppendF("{0} = ", key);
				EmitInlineArray(root[scope String(key)].GetArray(), output);
				output.Append("\n");
			}

			output.Append("\n");

			// and finally tables
			for(var key in tableKeys)
			{
				output.AppendF("[{0}]\n", key);
				EmitTableContents(root[scope String(key)].GetTable(), output);
				output.Append("\n");
			}
		}

		private static void EmitTableContents(TomlTableNode node, String output)
		{
			for(var key in node.Keys)
			{
				var val = node[key];

				output.AppendF("{0} = ", key);
				Emit(val, output);
				output.Append("\n");
			}
		}

		private static void Emit(TomlNode node, String output)
		{
			if(node.Kind == .Table)
			{
				EmitInlineTable(node.GetTable(), output);
			}
			else if(node.Kind == .Array)
			{
				EmitInlineArray(node.GetArray(), output);
			}
			else if(node.Kind == .String)
			{
				output.AppendF("\"{0}\"", node.GetString().Value);
			}
			else
			{
				output.Append(node.GetString().Value);
			}
		}

		private static void EmitInlineArray(TomlArrayNode node, String output)
		{
			output.Append("[ ");

			for(int i = 0; i < node.Count; i++)
			{
				Emit(node[i], output);
				if(i < node.Count - 1)
					output.Append(", ");
			}

			output.Append(" ]");
		}

		private static void EmitInlineTable(TomlTableNode node, String output)
		{
			output.Append("{ ");

			bool prev = false;
			for(var key in node.Keys)
			{
				if( prev )
					output.Append(", ");

				output.AppendF("{0} = ", key);
				Emit(node[key], output);

				prev = true;
			}

			output.Append(" }");
		}

		private static List<DataMember> GetDataMembers(Type type)
		{
			var dataMembers = new List<DataMember>();
			var fields = type.GetFields();
			bool isContract = type.GetCustomAttribute<DataContractAttribute>() case .Ok;

			for (let field in fields)
			{
				StringView fieldName = field.Name;
				if (fieldName.StartsWith("prop__"))
					fieldName = StringView(field.Name, 6);

				if (field.GetCustomAttribute<DataMemberAttribute>() case .Ok(let val))
				{
					if (val.Name != "")
						fieldName = StringView(val.Name);
				}	
				else if (isContract || field.GetCustomAttribute<NotDataMemberAttribute>() case .Ok)
					continue;

				dataMembers.Add(new DataMember(fieldName, field));
			}
			
			return dataMembers;
		}

		/*private void ToTomlNode(Object object, out TomlNode node)
		{
			TomlValueType valueType = ?;

			switch (object.GetType())
			{
			case typeof(Dictionary<String, Object>):
				valueType = .Table;
				break;
			case typeof(List<Object>):
				valueType = .Array;
				break;
			case typeof(String):
				valueType = .String;
				break;
			case typeof(int):
				valueType = .Int;
				break;
			case typeof(float):
				valueType = .Float;
				break;
			case typeof(bool):
				valueType = .Bool;
				break;
			case typeof(DateTime):
				valueType = .Datetime;
				break;
			default:
				node = null;
				return;
			}

			if (valueType == .Table)
			{
				var tableNode = new TomlTableNode();
				var dict = (Dictionary<String, Object>) object;
				for (var child in dict)
				{
					ToTomlNode(child.value, var valueNode);
					tableNode.AddChild(child.key, valueNode);
				}
			}
			else if (valueType == .Array)
			{
				var arrayNode = new TomlArrayNode();
				var list = (List<Object>) object;
				for (var child in list)
				{
					ToTomlNode(child, var valueNode);
					arrayNode.AddChild(valueNode);
				}
			}
			else
			{
				node = new TomlValueNode(.)
			}
		}*/

		private class DataMember
		{
			public String Name = new .() ~ delete _;
			public FieldInfo FieldInfo;

			public this(StringView name, FieldInfo fieldInfo)
			{
				Name.Set(name);
				FieldInfo = fieldInfo;
			}
		}
	}
}

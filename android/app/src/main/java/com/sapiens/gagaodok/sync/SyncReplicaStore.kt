package com.sapiens.gagaodok.sync

import java.io.File
import java.io.FileOutputStream
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

class SyncReplicaStoreException(message:String):Exception(message)
data class SyncReplicaEntry(val entityType:String,val identityJson:String,val projectionJson:String)

/** Opaque remote shadow store with no reference to ChatStore or its files. */
class SyncReplicaStore(private val file:File){
 @Serializable private data class Stored(val version:Int=1,val entries:List<Entry>)
 @Serializable private data class Entry(val key:String,val entityType:String,val identityJson:String,val projectionJson:String)
 @Synchronized fun apply(itemsJson:ByteArray){
  if(itemsJson.size>8_000_000)throw SyncReplicaStoreException("invalid page")
  val replacements=runCatching{
   val array=Json.parseToJsonElement(itemsJson.toString(Charsets.UTF_8)) as JsonArray
   array.map{element->
    val item=element.jsonObject;require(item.keys==setOf("entity_type","identity","projection"))
    val type=item.getValue("entity_type").jsonPrimitive.content;require(type in ENTITY_TYPES)
    val identity=item.getValue("identity") as JsonObject;val projection=item.getValue("projection") as JsonObject;require(identity.isNotEmpty())
    val identityJson=canonical(identity);val projectionJson=canonical(projection);require(identityJson.length<=16_384&&projectionJson.length<=2_000_000)
    Entry("$type:"+java.util.Base64.getEncoder().encodeToString(identityJson.toByteArray()),type,identityJson,projectionJson)
   }
  }.getOrElse{throw SyncReplicaStoreException("invalid page")}
  val current=load().entries.associateBy{it.key}.toMutableMap();replacements.forEach{current[it.key]=it};persist(Stored(entries=current.values.sortedBy{it.key}))
 }
 @Synchronized fun snapshot():List<SyncReplicaEntry> = load().entries.map{SyncReplicaEntry(it.entityType,it.identityJson,it.projectionJson)}
 private fun load():Stored{if(!file.exists())return Stored(entries=emptyList());return runCatching{Json.decodeFromString<Stored>(file.readText()).also{require(it.version==1)}}.getOrElse{throw SyncReplicaStoreException("corrupt store")}}
 private fun persist(stored:Stored){file.parentFile?.mkdirs();val temp=File(file.parentFile,"${file.name}.tmp");FileOutputStream(temp).use{it.write(Json.encodeToString(Stored.serializer(),stored).toByteArray());it.fd.sync()};if(!temp.renameTo(file)){temp.delete();throw SyncReplicaStoreException("atomic replace failed")}}
 companion object{
  private val ENTITY_TYPES=setOf("room","group_state","worldline","turn","bubble","engine_profile","persona_snapshot","checkpoint","attachment")
  private fun canonical(value:JsonObject):String="{"+value.entries.sortedBy{it.key}.joinToString(","){(key,item)->JsonPrimitive(key).toString()+":"+when(item){is JsonObject->canonical(item);is JsonArray->"["+item.joinToString(","){child->if(child is JsonObject)canonical(child)else child.toString()}+"]";else->item.toString()}}+"}"
 }
}

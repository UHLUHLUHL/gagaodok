package com.sapiens.gagaodok.sync

import android.content.Context
import java.security.MessageDigest
import java.util.Locale

class SyncRecoveryMnemonicException : Exception()

object SyncRecoveryMnemonic {
    fun bundledWords(context: Context): List<String> = context.assets.open("english-bip39.txt").bufferedReader().use { words(it.readText()) }
    fun words(text: String): List<String> = text.lineSequence().filter { it.isNotEmpty() }.toList().also {
        if (it.size != 2_048 || it.toSet().size != 2_048 || it.any { word -> !word.matches(Regex("[a-z]+")) }) throw SyncRecoveryMnemonicException()
    }
    fun encode(entropy: ByteArray, words: List<String>): String {
        if (entropy.size != 16 || words.size != 2_048) throw SyncRecoveryMnemonicException()
        val checksum = (MessageDigest.getInstance("SHA-256").digest(entropy)[0].toInt() ushr 4) and 0xf
        var accumulator=0;var bits=0;val indices=mutableListOf<Int>()
        for(byte in entropy + byteArrayOf((checksum shl 4).toByte())){accumulator=(accumulator shl 8)or(byte.toInt()and 255);bits+=8;while(bits>=11&&indices.size<12){bits-=11;indices+=(accumulator ushr bits)and 0x7ff};accumulator=if(bits==0)0 else accumulator and ((1 shl bits)-1)}
        return indices.joinToString(" "){words[it]}
    }
    fun decode(phrase:String,words:List<String>):ByteArray{
        if(words.size!=2_048)throw SyncRecoveryMnemonicException();val normalized=phrase.trim().lowercase(Locale.ROOT).split(Regex("\\s+")).filter{it.isNotEmpty()};if(normalized.size!=12)throw SyncRecoveryMnemonicException();val lookup=words.withIndex().associate{it.value to it.index};var accumulator=0;var bits=0;val bytes=mutableListOf<Byte>();for(word in normalized){val index=lookup[word]?:throw SyncRecoveryMnemonicException();accumulator=(accumulator shl 11)or index;bits+=11;while(bits>=8){bits-=8;bytes+=((accumulator ushr bits)and 255).toByte()};accumulator=if(bits==0)0 else accumulator and ((1 shl bits)-1)};if(bytes.size!=16||bits!=4)throw SyncRecoveryMnemonicException();val entropy=bytes.toByteArray();val expected=(MessageDigest.getInstance("SHA-256").digest(entropy)[0].toInt()ushr 4)and 0xf;if((accumulator and 0xf)!=expected)throw SyncRecoveryMnemonicException();return entropy
    }
}
